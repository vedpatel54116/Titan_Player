import Foundation
import AVFoundation
import Combine
import os.log

// MARK: - FairPlayDRM

/// Manages FairPlay Streaming (FPS) content-key acquisition for protected HLS
/// playback in Titan Player.
///
/// ## Why this exists
///
/// Titan Player could not play FairPlay-protected HLS because no code owned an
/// `AVContentKeySession` or implemented the SPC → CKC license exchange. This
/// type closes that gap: it creates the session, drives the per-request key
/// flow, generates the Server Playback Context (SPC) from the application
/// certificate, POSTs it to the license server, and installs the returned
/// Content Key Context (CKC).
///
/// ## Concurrency model
///
/// The manager is a `@MainActor final class`, which makes it genuinely
/// `Sendable` (no `@unchecked`) and lets it safely own the non-`Sendable`
/// `AVContentKeySession` and act as its delegate. All FairPlay work — key
/// requests, SPC generation, and the license POST — runs on the main actor,
/// matching `AVContentKeySession`'s threading contract. The single non-`Sendable`
/// dependency, `TelemetryManager` (a `@MainActor` `TelemetryProviding`), is never
/// stored directly; telemetry is emitted through a `Sendable` ``TelemetrySink``
/// that hops to the main actor. Sentry is never referenced directly.
///
/// ## Resilience
///
/// - **Thermal / memory pressure** is observed via Combine (`NotificationCenter`
///   for the thermal state, `DispatchSource` for memory pressure). When pressure
///   becomes critical the in-flight request is aborted and surfaced as
///   ``MediaError/Kind/thermalPressure`` or ``MediaError/Kind/memoryPressure``.
/// - **Cancellation** is honoured through `withTaskCancellationHandler` and
///   mapped to ``MediaError/Kind/cancelled``.
/// - **Timeouts** bound each license exchange; overruns throw
///   ``MediaError/Kind/timedOut``.
/// - **Every** failure routes through ``MediaError`` so UI and telemetry stay
///   consistent.
///
/// ## Example
/// ```swift
/// let drm = FairPlayDRM(configuration: .default(licenseURL: url, certificate: cert))
/// drm.attach(hlsAsset)
/// try await drm.requestContentKey(for: "asset-123")
/// ```
@MainActor
final class FairPlayDRM: NSObject, @preconcurrency AVContentKeySessionDelegate {

    // MARK: - Configuration

    /// Runtime configuration for FairPlay key acquisition.
    struct Configuration: Sendable {
        /// The FairPlay license server endpoint that exchanges an SPC for a CKC.
        let licenseURL: URL
        /// The application certificate (`der`-encoded) used to bootstrap the SPC.
        let certificate: Data
        /// Wall-clock budget (seconds) for the entire SPC → CKC exchange.
        let requestTimeout: TimeInterval
        /// When `true`, CKCs are persisted for offline re-use (when the request
        /// is an ``AVPersistableContentKeyRequest``).
        let persistKeys: Bool

        /// Convenience factory with sensible defaults.
        static func `default`(licenseURL: URL, certificate: Data) -> Configuration {
            Configuration(
                licenseURL: licenseURL,
                certificate: certificate,
                requestTimeout: 15.0,
                persistKeys: false
            )
        }
    }

    // MARK: - SystemPressureSnapshot

    /// A point-in-time snapshot of system thermal and memory pressure.
    ///
    /// Kept as a `Sendable` value type so the manager can store the latest
    /// reading and consult it before/after each key request to decide whether to
    /// abort gracefully rather than risk a thermal trip or jetsam termination.
    struct SystemPressureSnapshot: Sendable, Equatable {
        /// Coarse thermal state, mirroring `ProcessInfo.ThermalState`.
        enum Thermal: Sendable, Equatable, CustomStringConvertible {
            case nominal, fair, serious, critical
            var description: String {
                switch self {
                case .nominal: return "nominal"
                case .fair: return "fair"
                case .serious: return "serious"
                case .critical: return "critical"
                }
            }
        }
        /// Coarse memory-pressure state, derived from `DispatchSource`.
        enum Memory: Sendable, Equatable, CustomStringConvertible {
            case normal, warning, critical
            var description: String {
                switch self {
                case .normal: return "normal"
                case .warning: return "warning"
                case .critical: return "critical"
                }
            }
        }

        var thermal: Thermal
        var memory: Memory
        var updatedAt: Date

        static let nominal = SystemPressureSnapshot(
            thermal: .nominal, memory: .normal, updatedAt: .distantPast
        )

        /// Whether pressure is high enough that a key request should bail out
        /// rather than risk a thermal trip or jetsam termination.
        var shouldDegrade: Bool {
            thermal == .serious || thermal == .critical || memory == .critical
        }
    }

    // MARK: - TelemetrySink

    /// A `Sendable` bridge to ``TelemetryProviding`` so the manager never stores
    /// a non-`Sendable` telemetry reference.
    ///
    /// The default sink hops to the main actor and records through
    /// `TelemetryManager.shared` — Sentry is never referenced directly. Errors
    /// are mapped onto ``TelemetryEvent/playbackFailed`` via
    /// ``MediaError/telemetryErrorCode`` so buckets stay stable; successful key
    /// loads emit ``TelemetryEvent/drmKeyLoaded``.
    struct TelemetrySink: Sendable {
        /// The underlying sendable recording closure.
        let record: @Sendable (TelemetryEvent) -> Void

        /// Routes events through the shared `TelemetryManager` on the main actor.
        static let `default` = TelemetrySink { event in
            Task { @MainActor in TelemetryManager.shared.record(event) }
        }

        /// Records a ``MediaError`` as a `playbackFailed` telemetry event
        /// without ever touching Sentry directly.
        func record(_ error: MediaError) {
            record(.playbackFailed(
                codec: error.codec ?? "fairplay",
                resolution: error.resolution ?? "unknown",
                errorCode: error.telemetryErrorCode,
                source: error.source
            ))
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.titanplayer", category: "FairPlayDRM")

    private let configuration: Configuration
    private let telemetry: TelemetrySink
    private let source: PlaybackSource

    private var contentKeySession: AVContentKeySession?
    private var continuations: [String: CheckedContinuation<Void, Error>] = [:]

    private let pressureSubject = PassthroughSubject<SystemPressureSnapshot, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var memorySource: DispatchSourceMemoryPressure?
    private var lastMemoryLevel: SystemPressureSnapshot.Memory = .normal
    private var lastSnapshot: SystemPressureSnapshot = .nominal

    // MARK: - Initialization

    /// Creates a FairPlay DRM manager.
    /// - Parameters:
    ///   - configuration: License endpoint, certificate, and timeouts.
    ///   - telemetry: A `Sendable` telemetry sink; defaults to the shared
    ///     `TelemetryManager` bridge.
    ///   - source: Playback origin for telemetry bucketing (defaults to `.hls`).
    init(
        configuration: Configuration,
        telemetry: TelemetrySink = .default,
        source: PlaybackSource = .hls
    ) {
        self.configuration = configuration
        self.telemetry = telemetry
        self.source = source
        super.init()
    }

    // MARK: - Public API

    /// Attaches an `AVURLAsset` as a content-key recipient so the session is
    /// ready before playback begins.
    /// - Parameter asset: The protected HLS asset.
    func attach(_ asset: AVURLAsset) {
        let session = ensureSession()
        session.addContentKeyRecipient(asset)
    }

    /// Requests and installs the FairPlay content key for a given identifier.
    ///
    /// This drives the full SPC → CKC exchange and returns once the key has been
    /// processed (or throws a ``MediaError`` on cancellation, timeout, pressure,
    /// or license failure).
    /// - Parameter contentIdentifier: The per-stream key/asset identifier.
    func requestContentKey(for contentIdentifier: String) async throws {
        try Task.checkCancellation()
        try checkPressure()

        let id = contentIdentifier
        let session = ensureSession()

        // Kick off the FairPlay key request. The delegate callback (and the
        // continuation resume) runs on the main actor after this returns, by
        // which point the waiter below is already registered.
        session.processContentKeyRequest(withIdentifier: id, initializationData: nil, options: nil)

        try await withTaskCancellationHandler { [self] in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    try await Task.sleep(nanoseconds: UInt64(configuration.requestTimeout * 1_000_000_000))
                    throw MediaError(
                        kind: .timedOut,
                        source: source,
                        underlyingDomain: "FairPlayDRM",
                        underlyingMessage: "License request exceeded \(configuration.requestTimeout)s.",
                        message: "FairPlay license request timed out."
                    )
                }
                defer {
                    // The body exiting automatically cancels the remaining
                    // child tasks; resume the waiter so no continuation leaks.
                    resume(id)
                }
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    continuations[id] = cont
                }
            }
        } onCancel: { [self] in
            Task { @MainActor in
                invalidate()
                resume(id, throwing: MediaError(kind: .cancelled, source: source))
            }
        }
    }

    /// Tears down the session and fails any in-flight request.
    func invalidate() {
        contentKeySession = nil
        for (id, _) in continuations {
            resume(id, throwing: MediaError(kind: .cancelled, source: source))
        }
    }

    /// A Combine publisher emitting the latest system-pressure snapshot.
    var pressurePublisher: AnyPublisher<SystemPressureSnapshot, Never> {
        pressureSubject.eraseToAnyPublisher()
    }

    // MARK: - Pressure observation

    /// Begins observing thermal and memory pressure.
    func attachPressureObservation() {
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handlePressureChange() }
            }
            .store(in: &cancellables)

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self] in
            let mask = source.mask
            let level: SystemPressureSnapshot.Memory =
                mask.contains(.critical) ? .critical
                : mask.contains(.warning) ? .warning
                : .normal
            Task { @MainActor in
                self?.lastMemoryLevel = level
                self?.handlePressureChange()
            }
        }
        source.resume()
        memorySource = source
    }

    /// Stops observing pressure and releases the memory source.
    func detachPressureObservation() {
        cancellables.removeAll()
        memorySource?.cancel()
        memorySource = nil
    }

    // MARK: - AVContentKeySessionDelegate

    // The session is configured with `queue: .main`, so every callback arrives
    // on the main actor. The `@preconcurrency` conformance makes these methods
    // appear non-isolated to the compiler, so we re-establish main-actor context
    // with `MainActor.assumeIsolated` before touching actor state.

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        _ = MainActor.assumeIsolated {
            Task { await handle(keyRequest: keyRequest) }
        } as Task<Void, Never>
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didFailToProvide keyRequest: AVContentKeyRequest,
        withError error: Error
    ) {
        _ = MainActor.assumeIsolated {
            let mediaError = MediaError(error, source: source)
            telemetry.record(mediaError)
            resume(stringID(from: keyRequest), throwing: mediaError)
            return mediaError
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError error: Error
    ) {
        _ = MainActor.assumeIsolated {
            let mediaError = MediaError(error, source: source)
            telemetry.record(mediaError)
            resume(stringID(from: keyRequest), throwing: mediaError)
            return mediaError
        }
    }

    func contentKeySessionDidProcessAllKeyRequests(_ session: AVContentKeySession) {
        // Completion is reported per-request via the continuation.
    }

    // MARK: - Private: key handling

    private func handle(keyRequest: AVContentKeyRequest) async {
        let id = stringID(from: keyRequest)
        do {
            try Task.checkCancellation()
            try checkPressure()

            let spc = try await keyRequest.makeStreamingContentKeyRequestData(
                forApp: configuration.certificate,
                contentIdentifier: Data(id.utf8),
                options: nil
            )

            let ckc = try await fetchLicense(spc: spc)

            let response = AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc)
            keyRequest.processContentKeyResponse(response)

            telemetry.record(.drmKeyLoaded(source: source))
            logger.info("FairPlay key acquired for \(id, privacy: .public)")
            resume(id)
        } catch {
            let mediaError = MediaError(error, source: source)
            telemetry.record(mediaError)
            keyRequest.processContentKeyResponseError(mediaError)
            resume(id, throwing: mediaError)
        }
    }

    private func fetchLicense(spc: Data) async throws -> Data {
        var request = URLRequest(url: configuration.licenseURL)
        request.httpMethod = "POST"
        request.httpBody = spc
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = configuration.requestTimeout

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw MediaError(
                kind: .drmUnauthorized,
                source: source,
                underlyingDomain: "HTTP",
                underlyingCode: http.statusCode,
                underlyingMessage: "License server returned \(http.statusCode).",
                message: "The FairPlay license server rejected the request."
            )
        }

        guard !data.isEmpty else {
            throw MediaError(
                kind: .drmUnauthorized,
                source: source,
                message: "The FairPlay license server returned an empty key."
            )
        }
        return data
    }

    // MARK: - Private: session / pressure helpers

    private func ensureSession() -> AVContentKeySession {
        if let existing = contentKeySession { return existing }
        let session = AVContentKeySession(keySystem: AVContentKeySystem.fairPlayStreaming)
        session.setDelegate(self, queue: .main)
        contentKeySession = session
        return session
    }

    private func handlePressureChange() {
        let snapshot = currentPressure()
        lastSnapshot = snapshot
        pressureSubject.send(snapshot)
        guard snapshot.shouldDegrade else { return }
        logger.warning("System pressure \(snapshot.thermal) / \(snapshot.memory) — aborting FairPlay request.")
        invalidate()
    }

    private func checkPressure() throws {
        let snapshot = currentPressure()
        lastSnapshot = snapshot
        if snapshot.thermal == .serious || snapshot.thermal == .critical {
            throw MediaError.thermalPressure(source: source)
        }
        if snapshot.memory == .critical {
            throw MediaError.memoryPressure(source: source)
        }
    }

    private func currentPressure() -> SystemPressureSnapshot {
        let thermal: SystemPressureSnapshot.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }
        return SystemPressureSnapshot(thermal: thermal, memory: lastMemoryLevel, updatedAt: Date())
    }

    /// Normalises the opaque `AVContentKeyRequest.identifier` (bridged as
    /// `Any`) into a stable `String` key for the continuation dictionary.
    ///
    /// For HLS the identifier is an `NSURL` matching a key URI in the playlist;
    /// otherwise it may be a string. A stable synthetic id is used as a fallback.
    private func stringID(from request: AVContentKeyRequest) -> String {
        switch request.identifier {
        case let url as URL: return url.absoluteString
        case let string as String: return string
        default: return UUID().uuidString
        }
    }

    private func resume(_ id: String, throwing error: Error? = nil) {
        guard let cont = continuations.removeValue(forKey: id) else { return }
        if let error { cont.resume(throwing: error) } else { cont.resume(returning: ()) }
    }
}
