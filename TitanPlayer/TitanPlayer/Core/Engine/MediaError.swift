import Foundation
import AVFoundation

// MARK: - MediaError

/// A centralized, `Sendable` error type for Titan Player.
///
/// Titan Player historically threw a stringly-typed ``MediaError`` (decoder
/// layer) and a `PlaybackError` (engine layer) with no unified shape, which
/// made recovery logic, telemetry mapping, and diagnostics inconsistent. This
/// type replaces both as the single source of truth:
///
/// - Every thrown error from any subsystem — network, decoding, rendering,
///   system pressure — is funneled through ``init(_:source:)`` into a stable
///   ``Kind``. Callers never surface a raw `Error` to UI or telemetry.
/// - All stored properties are value types, so the type is **genuinely**
///   `Sendable` (no `@unchecked`) and safe to cross actor boundaries. The
///   underlying `Error` is decomposed into `domain` / `code` / `message` so the
///   salient information survives without capturing a non-`Sendable` reference.
/// - Telemetry is emitted **only** through the ``TelemetryProviding`` protocol
///   (which wraps Sentry), never by touching Sentry directly. See
///   ``record(using:)``.
/// - The legacy `MediaError(code:message:)` / `.code` / `.message` surface is
///   preserved so existing decoder and pipeline call sites keep compiling;
///   those map onto the canonical ``Kind``.
///
/// ### Example
/// ```swift
/// do {
///     try await pipeline.start()
/// } catch {
///     let mediaError = MediaError(error, source: .local)
///     present(mediaError)
///     mediaError.record()
/// }
/// ```
struct MediaError: Sendable, Error, LocalizedError, Equatable, Codable, CustomStringConvertible {

    // MARK: Kind

    /// The stable classification of a media failure.
    ///
    /// `Kind` is a plain tagged enum (no associated values) so it is trivially
    /// `Codable`, `Equatable`, and `CaseIterable`, which lets callers switch on
    /// it exhaustively for recovery strategies and telemetry bucketing.
    enum Kind: Sendable, Equatable, Codable, CaseIterable {
        /// The supplied file or network URL could not be used.
        case invalidURL
        /// The asset could not be loaded (corrupt, missing, unsupported container).
        case assetLoadFailed
        /// The asset contains no tracks Titan Player can present.
        case noPlayableTracks
        /// A video/audio frame could not be decoded (hardware or software).
        case decodingFailed
        /// The audio device / graph could not be configured or failed mid-stream.
        case audioOutputFailed
        /// The requested playback rate is unsupported by the active backend.
        case rateNotSupported
        /// A seek operation could not be completed.
        case seekFailed
        /// The network is unavailable or the connection was lost.
        case networkUnavailable
        /// The Metal renderer failed (device lost, shader compile, command buffer).
        case rendererFailure
        /// The system entered a thermal pressure state and throttled the app.
        case thermalPressure
        /// The system is under memory pressure and may terminate the app.
        case memoryPressure
        /// The in-flight operation was cancelled (e.g. task tree torn down).
        case cancelled
        /// An operation exceeded its allotted time budget.
        case timedOut
        /// The media format / codec is not supported by any available decoder.
        case formatUnsupported
        /// A FairPlay (or other DRM) license server rejected the request or
        /// returned an unusable content key.
        case drmUnauthorized
        /// Any error that does not match a known category.
        case unknown
    }

    // MARK: ErrorCode (legacy compatibility)

    /// Legacy integer-coded error categories retained for backward
    /// compatibility with decoder and pipeline call sites. Prefer switching on
    /// ``kind`` for new code; this maps onto ``Kind`` losslessly enough for
    /// existing consumers.
    enum ErrorCode: Int, Sendable, Equatable, Codable {
        case fileNotFound = 1
        case unsupportedFormat = 2
        case decodingFailed = 3
        case networkError = 4
        case systemPressure = 5
    }

    // MARK: Stored properties

    /// The classified failure category (canonical).
    let kind: Kind

    /// Where playback originated, used to bucket telemetry.
    let source: PlaybackSource

    /// Domain of the underlying system error, when available (e.g.
    /// `AVFoundationErrorDomain`). `nil` for system-pressure errors.
    let underlyingDomain: String?

    /// Numeric code of the underlying system error, when available.
    let underlyingCode: Int?

    /// Human-readable message of the underlying error, when available.
    let underlyingMessage: String?

    /// Codec context (e.g. `"hevc"`, `"av1"`) attached for telemetry.
    let codec: String?

    /// Resolution context (e.g. `"3840x2160"`) attached for telemetry.
    let resolution: String?

    /// Monotonic timestamp captured when the error was constructed.
    let timestamp: Date

    /// Human-readable message. Mirrors legacy `MediaError.message` and backs
    /// `errorDescription`.
    let message: String

    // MARK: Legacy accessors

    /// The legacy integer-coded category, derived from ``kind``.
    var code: ErrorCode { Self.errorCode(for: kind) }

    // MARK: Initialization

    /// Creates a ``MediaError`` by classifying an arbitrary `Error`.
    ///
    /// This is the single funnel through which every subsystem routes its
    /// failures. The mapping order is most-specific-first: structured error
    /// types (`CancellationError`, `URLError`, `AVError`) are checked, then raw
    /// `NSError` domain/code inspection covers VideoToolbox (`VTToolboxErrorDomain`)
    /// and Metal (`MTL*` domains), with `unknown` as the terminal default.
    ///
    /// - Parameters:
    ///   - error: The raw error thrown by any Titan Player subsystem.
    ///   - source: The playback origin; defaults to `.local`.
    ///   - codec: Optional codec label for telemetry.
    ///   - resolution: Optional resolution label for telemetry.
    init(
        _ error: some Error,
        source: PlaybackSource = .local,
        codec: String? = nil,
        resolution: String? = nil
    ) {
        let ns = error as NSError
        self.init(
            kind: Self.classify(error),
            source: source,
            underlyingDomain: ns.domain,
            underlyingCode: ns.code,
            underlyingMessage: error.localizedDescription,
            codec: codec,
            resolution: resolution,
            timestamp: Date(),
            message: error.localizedDescription
        )
    }

    /// Legacy constructor preserved for decoder / pipeline call sites.
    init(code: ErrorCode, message: String, source: PlaybackSource = .local) {
        self.init(
            kind: Self.kind(for: code),
            source: source,
            message: message
        )
    }

    /// Designated memberwise initializer (exposed for factories and tests).
    init(
        kind: Kind,
        source: PlaybackSource,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil,
        underlyingMessage: String? = nil,
        codec: String? = nil,
        resolution: String? = nil,
        timestamp: Date = Date(),
        message: String? = nil
    ) {
        self.kind = kind
        self.source = source
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
        self.underlyingMessage = underlyingMessage
        self.codec = codec
        self.resolution = resolution
        self.timestamp = timestamp
        self.message = message ?? Self.describe(kind)
    }

    // MARK: System-pressure factories

    /// Creates an error for the current thermal-pressure state.
    ///
    /// Thermal pressure is reported by the OS via `ProcessInfo.thermalState`,
    /// not thrown, so it is constructed explicitly rather than via
    /// ``init(_:source:)``.
    static func thermalPressure(
        state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
        source: PlaybackSource = .local
    ) -> MediaError {
        MediaError(
            kind: .thermalPressure,
            source: source,
            underlyingDomain: "NSProcessInfo",
            underlyingCode: Int(state.rawValue),
            underlyingMessage: "Thermal state: \(state.titanDescription)",
            message: "The system is under thermal pressure (\(state.titanDescription))."
        )
    }

    /// Creates an error for current memory pressure.
    ///
    /// Memory pressure comes from `DispatchSource.MemoryPressure` notifications,
    /// not thrown errors. Callers that can resolve the remaining available
    /// memory may pass it via `availableBytes` for diagnostics; otherwise a
    /// generic message is used.
    static func memoryPressure(
        availableBytes: UInt64? = nil,
        source: PlaybackSource = .local
    ) -> MediaError {
        let message: String
        if let availableBytes {
            let mb = Double(availableBytes) / (1024 * 1024)
            message = String(format: "The system is under memory pressure (~%.1f MB available).", mb)
        } else {
            message = "The system is under memory pressure."
        }
        return MediaError(
            kind: .memoryPressure,
            source: source,
            underlyingDomain: "NSProcessInfo",
            underlyingMessage: message
        )
    }

    // MARK: Classification

    /// Maps an arbitrary error to its ``Kind``.
    ///
    /// Order matters: structured Swift error types are preferred over raw
    /// `NSError` inspection. Anything unrecognized becomes ``Kind/unknown``.
    private static func classify(_ error: some Error) -> Kind {
        if error is CancellationError {
            return .cancelled
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timedOut
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .resourceUnavailable:
                return .networkUnavailable
            case .cancelled:
                return .cancelled
            case .unsupportedURL, .fileDoesNotExist:
                return .invalidURL
            default:
                return .assetLoadFailed
            }
        }

        if error is AVError {
            return classifyAVError(error as! AVError)
        }

        if let ns = error as NSError? {
            // VideoToolbox surfaces failures as NSError under this domain.
            if ns.domain == "VTToolboxErrorDomain" {
                return .decodingFailed
            }
            // Metal command-buffer / compiler / device failures use MTL* domains.
            if ns.domain.hasPrefix("MTL") {
                return .rendererFailure
            }
            switch (ns.domain, ns.code) {
            case (NSPOSIXErrorDomain, Int(ETIMEDOUT)):
                return .timedOut
            case (NSPOSIXErrorDomain, Int(ECANCELED)):
                return .cancelled
            case ("AVFoundationErrorDomain", _):
                return .assetLoadFailed
            default:
                break
            }
        }

        return .unknown
    }

    /// Refines an `AVError` into a more specific ``Kind``.
    ///
    /// `AVError` carries many codes; only the stable, long-standing cases are
    /// switched explicitly and everything else degrades to ``Kind/assetLoadFailed``
    /// while preserving the underlying message.
    private static func classifyAVError(_ error: AVError) -> Kind {
        switch error.code {
        case .noSourceTrack:
            return .noPlayableTracks
        case .decodeFailed, .decoderNotFound, .decoderTemporarilyUnavailable:
            return .decodingFailed
        case .operationNotSupportedForAsset:
            return .rateNotSupported
        case .failedToParse, .unsupportedOutputSettings:
            return .formatUnsupported
        case .fileAlreadyExists, .deviceNotConnected, .noLongerPlayable:
            return .assetLoadFailed
        default:
            return .assetLoadFailed
        }
    }

    // MARK: Kind <-> ErrorCode bridging

    private static func kind(for code: ErrorCode) -> Kind {
        switch code {
        case .fileNotFound: return .invalidURL
        case .unsupportedFormat: return .formatUnsupported
        case .decodingFailed: return .decodingFailed
        case .networkError: return .networkUnavailable
        case .systemPressure: return .memoryPressure
        }
    }

    private static func errorCode(for kind: Kind) -> ErrorCode {
        switch kind {
        case .invalidURL, .assetLoadFailed:
            return .fileNotFound
        case .noPlayableTracks, .rateNotSupported, .formatUnsupported, .drmUnauthorized:
            return .unsupportedFormat
        case .decodingFailed, .audioOutputFailed, .seekFailed, .rendererFailure:
            return .decodingFailed
        case .networkUnavailable:
            return .networkError
        case .thermalPressure, .memoryPressure, .cancelled, .timedOut, .unknown:
            return .systemPressure
        }
    }

    // MARK: LocalizedError

    var errorDescription: String? { message }

    /// A detailed, multi-line description combining the category and any
    /// underlying system error metadata. Useful for logs and crash reports.
    var description: String {
        var parts = ["[MediaError.\(kind)] \(message)"]
        if let domain = underlyingDomain {
            parts.append("domain=\(domain)")
        }
        if let code = underlyingCode {
            parts.append("code=\(code)")
        }
        if let underlyingMessage, underlyingMessage != message {
            parts.append("underlying=\"\(underlyingMessage)\"")
        }
        if let codec {
            parts.append("codec=\(codec)")
        }
        if let resolution {
            parts.append("resolution=\(resolution)")
        }
        parts.append("source=\(source.rawValue)")
        return parts.joined(separator: " ")
    }

    // MARK: Codable

    /// Manual `Codable` so the type does not depend on ``PlaybackSource``
    /// (a shared, non-`Codable` enum) conforming to `Codable`. `source` is
    /// encoded through its `rawValue` string and recovered with a `.local`
    /// fallback when missing or unknown.
    private enum CodingKeys: String, CodingKey {
        case kind
        case source
        case underlyingDomain
        case underlyingCode
        case underlyingMessage
        case codec
        case resolution
        case timestamp
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        let sourceRaw = try container.decode(String.self, forKey: .source)
        source = PlaybackSource(rawValue: sourceRaw) ?? .local
        underlyingDomain = try container.decodeIfPresent(String.self, forKey: .underlyingDomain)
        underlyingCode = try container.decodeIfPresent(Int.self, forKey: .underlyingCode)
        underlyingMessage = try container.decodeIfPresent(String.self, forKey: .underlyingMessage)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        resolution = try container.decodeIfPresent(String.self, forKey: .resolution)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        message = try container.decode(String.self, forKey: .message)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(source.rawValue, forKey: .source)
        try container.encodeIfPresent(underlyingDomain, forKey: .underlyingDomain)
        try container.encodeIfPresent(underlyingCode, forKey: .underlyingCode)
        try container.encodeIfPresent(underlyingMessage, forKey: .underlyingMessage)
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encodeIfPresent(resolution, forKey: .resolution)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(message, forKey: .message)
    }

    // MARK: Telemetry

    /// A stable, snake_case identifier for the failure, used as the
    /// `errorCode` field of telemetry events.
    var telemetryErrorCode: String {
        switch kind {
        case .invalidURL: return "invalid_url"
        case .assetLoadFailed: return "asset_load_failed"
        case .noPlayableTracks: return "no_playable_tracks"
        case .decodingFailed: return "decoding_failed"
        case .audioOutputFailed: return "audio_output_failed"
        case .rateNotSupported: return "rate_not_supported"
        case .seekFailed: return "seek_failed"
        case .networkUnavailable: return "network_unavailable"
        case .rendererFailure: return "renderer_failure"
        case .thermalPressure: return "thermal_pressure"
        case .memoryPressure: return "memory_pressure"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed_out"
        case .formatUnsupported: return "format_unsupported"
        case .drmUnauthorized: return "drm_unauthorized"
        case .unknown: return "unknown"
        }
    }

    /// Emits this error to telemetry through the injected ``TelemetryProviding``
    /// protocol **only** — Sentry is never referenced directly.
    ///
    /// - Parameter telemetry: A telemetry sink (e.g. `TelemetryManager.shared`).
    ///   Must be called on the main actor because ``TelemetryProviding`` is
    ///   `@MainActor`.
    @MainActor
    func record(using telemetry: some TelemetryProviding) {
        telemetry.record(.playbackFailed(
            codec: codec ?? "unknown",
            resolution: resolution ?? "unknown",
            errorCode: telemetryErrorCode,
            source: source
        ))
    }

    /// Convenience that records through the shared ``TelemetryManager``.
    ///
    /// Equivalent to `record(using: TelemetryManager.shared)`; kept as a thin
    /// wrapper so call sites never name Sentry.
    @MainActor
    func record() {
        record(using: TelemetryManager.shared)
    }

    // MARK: Helpers

    private static func describe(_ kind: Kind) -> String {        switch kind {
        case .invalidURL: return "The file or stream URL is invalid."
        case .assetLoadFailed: return "The media asset could not be loaded."
        case .noPlayableTracks: return "No playable video or audio tracks were found."
        case .decodingFailed: return "A frame could not be decoded."
        case .audioOutputFailed: return "Audio output failed."
        case .rateNotSupported: return "The requested playback rate is not supported."
        case .seekFailed: return "Seeking failed."
        case .networkUnavailable: return "The network is unavailable."
        case .rendererFailure: return "The renderer failed."
        case .thermalPressure: return "The system is under thermal pressure."
        case .memoryPressure: return "The system is under memory pressure."
        case .cancelled: return "The operation was cancelled."
        case .timedOut: return "The operation timed out."
        case .formatUnsupported: return "The media format is not supported."
        case .drmUnauthorized: return "The FairPlay license or content key was rejected."
        case .unknown: return "An unknown playback error occurred."
        }
    }
}

// MARK: - ProcessInfo.ThermalState description

extension ProcessInfo.ThermalState {
    /// A short, human-readable label for the current thermal state.
    fileprivate var titanDescription: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
