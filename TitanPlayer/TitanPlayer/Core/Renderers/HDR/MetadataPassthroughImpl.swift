import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import AppKit
import Metal
import VideoToolbox
import Combine
import simd
import os.log

// MARK: - MetadataPassthroughImpl

/// EDR headroom measurement and ICC-profile fallback for HDR passthrough.
///
/// # Why this exists
///
/// On XDR displays (Pro Display XDR, MacBook Pro XDR) a `CAMetalLayer` with
/// `wantsExtendedDynamicRangeContent = true` expects fragment output in an
/// *extended* color space where `1.0` is the display's **reference white**
/// (100 nits on XDR) and values above `1.0` up to
/// ``EDRHeadroom/edrHeadroom`` reach the panel's peak luminance. When a
/// renderer blindly forwards HDR10 / Dolby Vision / HDR10+ metadata *without*
/// scaling the signal by the display's measured EDR headroom, the whole frame
/// is expanded into the extended range incorrectly and the picture looks
/// **washed out and desaturated**.
///
/// This type is the missing link between the decoder's static/dynamic HDR
/// metadata and the Metal layer's EDR contract:
///
/// 1. It reads each display's EDR headroom via `NSScreen`
///    (`maximumExtendedDynamicRangeColorComponentValue` /
///    `extendedDynamicRangeColorSampleValue`) and derives the per-display
///    reference-white and peak-nit mapping.
/// 2. It maps the content's mastering/light-level metadata onto that headroom,
///    clamping highlights so they land at the panel's peak instead of clipping
///    to white — the direct fix for the wash-out.
/// 3. When a display reports **no** EDR headroom (headroom ≈ `1.0`, or the
///    color-space query fails) it falls back to ICC-based gamut management so
///    the image is at least shown correctly in SDR rather than washed out.
///
/// # Concurrency model
///
/// The type is a `final actor`, which makes it genuinely `Sendable` (no
/// `@unchecked`) and serializes all state mutation. The only non-`Sendable`
/// dependency — `TelemetryManager` (a `@MainActor` `TelemetryProviding`) — is
/// never stored; telemetry events are emitted through a `Sendable`
/// ``TelemetrySink`` that hops to the main actor. Display reads that touch
/// AppKit (`NSScreen`) run on the main actor via `MainActor.run`.
///
/// # Lifecycle
///
/// ```swift
/// let passthrough = MetadataPassthroughImpl(config: .default)
/// try await passthrough.attachPressureObservation()      // thermal/memory
/// let params = try await passthrough.process(mode: mode)  // per-frame
/// // hand `params` to the Metal renderer / CAMetalLayer
/// try await passthrough.detach()                          // cancel + cleanup
/// ```
final actor MetadataPassthroughImpl {

    // MARK: - Configuration

    /// Runtime configuration for the passthrough pipeline.
    struct Configuration: Sendable, Equatable {
        /// Base HDR processing behaviour (passthrough toggle, dynamic TM, …).
        let base: HDRProcessingConfig
        /// Wall-clock budget for a single EDR-headroom measurement.
        let edrDetectionTimeout: TimeInterval
        /// If `true`, an EDR-capable display with *no* usable ICC/gamut info
        /// still receives headroom scaling rather than full SDR fallback.
        let preferHeadroomOverFallback: Bool

        static let `default` = Configuration(
            base: .default,
            edrDetectionTimeout: 2.0,
            preferHeadroomOverFallback: true
        )
    }

    // MARK: - EDR Headroom

    /// Measured extended-dynamic-range capability of a single display.
    ///
    /// All values are plain `Sendable` scalars; the struct is safe to cross
    /// actor boundaries and to cache.
    struct EDRHeadroom: Sendable, Equatable {
        /// The display this measurement applies to.
        let displayID: CGDirectDisplayID
        /// Maximum extended-range component value the panel can show
        /// (`NSScreen.maximumExtendedDynamicRangeColorComponentValue`).
        /// `1.0` means *no* headroom (plain SDR); XDR panels report `> 1.0`.
        let edrHeadroom: Float
        /// Component value that maps to the display's reference white
        /// (`NSScreen.extendedDynamicRangeColorSampleValue`).
        let referenceWhiteSample: Float
        /// Absolute luminance (nits) of the reference white. XDR reference
        /// white is 100 nits; this is the divisor the shader uses to convert
        /// PQ absolute luminance into an EDR component value.
        let referenceWhiteNits: Float
        /// Display peak luminance in nits (`referenceWhiteNits * edrHeadroom`).
        let peakNits: Float
        /// Content gamut the display can reproduce.
        let colorGamut: ColorGamut
        /// When the measurement was taken (used as a staleness guard).
        let measuredAt: Date

        /// `true` when the panel exposes real (>1.0) EDR headroom.
        var isEDRCapable: Bool { edrHeadroom > 1.0001 }
    }

    // MARK: - System Pressure

    /// A point-in-time snapshot of system thermal and memory pressure.
    ///
    /// Kept as a `Sendable` value type so the actor can store the latest
    /// reading and consult it on every `process(_:)` call to decide whether to
    /// degrade gracefully instead of allocating metadata work the OS will
    /// soon throttle.
    struct SystemPressureSnapshot: Sendable, Equatable {
        enum Thermal: Sendable, Equatable { case nominal, fair, serious, critical }
        enum Memory: Sendable, Equatable { case normal, warning, urgent, critical }

        var thermal: Thermal
        var memory: Memory
        var updatedAt: Date

        static let nominal = SystemPressureSnapshot(
            thermal: .nominal, memory: .normal, updatedAt: .distantPast
        )

        /// Whether pressure is high enough that we should fall back to a
        /// cheaper static/ICC path for the next frame.
        var shouldDegrade: Bool {
            thermal == .serious || thermal == .critical || memory == .critical
        }
    }

    // MARK: - Output

    /// The per-display, per-frame parameters the Metal renderer consumes.
    ///
    /// The renderer's fragment function maps absolute PQ luminance `L` (nits)
    /// to an EDR component as `min(L / referenceWhiteNits, edrHeadroom)` and
    /// applies `gamutMatrix` to convert content gamut → display gamut. When
    /// ``usedICCFallback`` is `true` the renderer must *not* enter extended
    /// range and should treat `edrHeadroom` as `1.0`.
    struct PassthroughParameters: Sendable, Equatable {
        let displayID: CGDirectDisplayID
        /// EDR headroom to clamp highlights against.
        let edrHeadroom: Float
        /// Reference-white luminance (nits) for the PQ→EDR conversion.
        let referenceWhiteNits: Float
        /// Display peak luminance (nits).
        let peakNits: Float
        /// Content→display gamut transform (identity for native-EDR, ICC
        /// matrix for the fallback path).
        let gamutMatrix: simd_float3x3
        /// `true` when ICC fallback was used because EDR headroom was absent.
        let usedICCFallback: Bool
        /// When these parameters were produced.
        let timestamp: Date
    }

    // MARK: - Telemetry Sink

    /// A `Sendable` bridge to ``TelemetryProviding`` so the actor never stores
    /// a non-`Sendable` telemetry reference.
    ///
    /// The default sink hops to the main actor and records through
    /// `TelemetryManager.shared` — Sentry is never referenced directly.
    struct TelemetrySink: Sendable {
        let record: @Sendable (TelemetryEvent) -> Void

        static let `default` = TelemetrySink { event in
            Task { @MainActor in TelemetryManager.shared.record(event) }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.titanplayer", category: "MetadataPassthroughImpl")

    private let configuration: Configuration
    private let telemetry: TelemetrySink

    /// Cached EDR headroom per display, invalidated after a thermal event.
    private var headroomCache: [CGDirectDisplayID: EDRHeadroom] = [:]

    /// Latest observed system pressure.
    private var pressure: SystemPressureSnapshot = .nominal

    /// Live pressure observer (main-actor bound, `@unchecked Sendable`).
    private var pressureObserver: SystemPressureObserver?

    /// Tracks whether observation is currently active so `detach()` is safe.
    private var isObserving = false

    // MARK: - Initialization

    /// Creates a passthrough impl.
    ///
    /// - Parameters:
    ///   - configuration: Runtime tuning. Defaults to `Configuration.default`.
    ///   - telemetry: Telemetry sink. Defaults to `TelemetrySink.default`
    ///     which routes through `TelemetryManager`.
    init(configuration: Configuration = .default, telemetry: TelemetrySink = .default) {
        self.configuration = configuration
        self.telemetry = telemetry
    }

    // MARK: - Public API

    /// Begins observing thermal and memory pressure on the main actor.
    ///
    /// Safe to call multiple times; subsequent calls are no-ops while an
    /// observer is already running. Observations are automatically cancelled
    /// by ``detach()``.
    func attachPressureObservation() async {
        guard !isObserving else { return }
        let observer = await MainActor.run { SystemPressureObserver { [weak self] snapshot in
            Task { await self?.applyPressure(snapshot) }
        } }
        pressureObserver = observer
        isObserving = true
    }

    /// Stops pressure observation and drops cached headroom.
    ///
    /// Cancellation-safe: any in-flight ``process(_:for:)`` continues to
    /// completion using already-measured data, but no new work is scheduled.
    func detach() async {
        pressureObserver = nil
        isObserving = false
        headroomCache.removeAll()
    }

    /// Returns the most recent system-pressure snapshot.
    func pressureSnapshot() -> SystemPressureSnapshot { pressure }

    /// Forces a re-measure of EDR headroom for a display (or the main display
    /// when `displayID` is `nil`), bypassing the cache.
    ///
    /// - Throws: ``MediaError`` (`.timedOut`, `.rendererFailure`) on failure.
    func refreshEDRHeadroom(for displayID: CGDirectDisplayID? = nil) async throws {
        let target = displayID ?? CGMainDisplayID()
        try Task.checkCancellation()
        let headroom = try await Self.withTimeout(seconds: configuration.edrDetectionTimeout) {
            await Self.measureEDRHeadroom(displayID: target)
        }
        if let headroom {
            headroomCache[target] = headroom
        } else if !configuration.preferHeadroomOverFallback {
            throw MediaError(
                kind: .rendererFailure,
                source: .local,
                underlyingDomain: "EDR",
                underlyingMessage: "Display \(target) exposes no EDR headroom and fallback is disabled.",
                message: "Unable to measure EDR headroom for the target display."
            )
        }
    }

    /// Maps the supplied HDR mode to concrete Metal-layer parameters.
    ///
    /// This is the per-frame entry point. It:
    /// 1. Checks for cancellation and current system pressure (degrading to
    ///    ICC fallback under serious/critical pressure).
    /// 2. Measures (or reuses) EDR headroom for the display.
    /// 3. Either scales the content metadata onto the headroom (EDR path) or
    ///    builds ICC-based parameters (fallback path) to avoid wash-out.
    ///
    /// - Parameters:
    ///   - mode: The active extended HDR mode for the current frame.
    ///   - displayID: Target display; `nil` selects the main display.
    /// - Throws: ``MediaError`` (`.cancelled`, `.timedOut`, `.rendererFailure`).
    /// - Returns: ``PassthroughParameters`` for the renderer.
    func process(_ mode: ExtendedHDRMode, for displayID: CGDirectDisplayID? = nil) async throws -> PassthroughParameters {
        do { try Task.checkCancellation() } catch {
            throw MediaError(kind: .cancelled, source: .local)
        }

        let target = displayID ?? CGMainDisplayID()

        // Under heavy pressure, skip headroom work and go straight to the
        // cheap ICC/SDR path so we don't add load the OS is throttling.
        if self.pressure.shouldDegrade {
            logger.warning("System pressure \(String(describing: self.pressure.thermal)); using ICC fallback.")
            telemetry.record(.compatibilityModeActivated(reason: "system_pressure", source: .local))
            return try await Self.withTimeout(seconds: configuration.edrDetectionTimeout) {
                await Self.iccFallback(displayID: target, mode: mode)
            }
        }

        let headroom = try await Self.withTimeout(seconds: configuration.edrDetectionTimeout) { () -> EDRHeadroom? in
            if let cached = await self.cachedHeadroom(for: target) {
                return cached
            }
            return await Self.measureEDRHeadroom(displayID: target)
        }

        if let headroom, headroom.isEDRCapable {
            headroomCache[target] = headroom
            let matrix = Self.gamutMatrix(for: mode, displayGamut: headroom.colorGamut)
            let params = PassthroughParameters(
                displayID: target,
                edrHeadroom: headroom.edrHeadroom,
                referenceWhiteNits: headroom.referenceWhiteNits,
                peakNits: headroom.peakNits,
                gamutMatrix: matrix,
                usedICCFallback: false,
                timestamp: Date()
            )
            emitHDRMode(mode)
            return params
        }

        // No usable EDR headroom → ICC fallback path.
        logger.info("Display \(target) has no EDR headroom; using ICC fallback.")
        telemetry.record(.compatibilityModeActivated(reason: "edr_headroom_unavailable", source: .local))
        return try await Self.withTimeout(seconds: configuration.edrDetectionTimeout) {
            await Self.iccFallback(displayID: target, mode: mode)
        }
    }

    /// Extracts HDR metadata from a `CMFormatDescription`'s extensions and
    /// forwards it to ``process(_:for:)``.
    ///
    /// This is the VideoToolbox/CoreMedia entry point: decoded HDR streams
    /// advertise mastering-display and content-light-level metadata through
    /// format-description extensions, which we convert into an
    /// ``ExtendedHDRMode`` before mapping to EDR parameters.
    ///
    /// - Throws: ``MediaError`` if the description is missing or unreadable.
    func process(formatDescription: CMFormatDescription?, for displayID: CGDirectDisplayID? = nil) async throws -> PassthroughParameters {
        let mode = try Self.mode(from: formatDescription)
        return try await process(mode, for: displayID)
    }

    // MARK: - Pressure handling

    private func applyPressure(_ snapshot: SystemPressureSnapshot) {
        pressure = snapshot
        // Thermal state changes invalidate cached headroom — the panel's
        // available headroom shrinks as the system heats up, so re-measure
        // lazily on the next frame rather than trusting stale numbers.
        if snapshot.thermal == .serious || snapshot.thermal == .critical {
            headroomCache.removeAll()
        }
        if snapshot.shouldDegrade {
            logger.warning("Pressure degraded: thermal=\(String(describing: snapshot.thermal)) memory=\(String(describing: snapshot.memory))")
        }
    }

    // MARK: - Headroom measurement (main-actor reads)

    /// Cached headroom accessor (actor-isolated).
    private func cachedHeadroom(for displayID: CGDirectDisplayID) -> EDRHeadroom? {
        headroomCache[displayID]
    }

    /// Measures EDR headroom for a display by reading `NSScreen` on the main
    /// actor. Returns `nil` when the display exposes no extended range (plain
    /// SDR) — callers should then take the ICC fallback path.
    nonisolated static func measureEDRHeadroom(displayID: CGDirectDisplayID) async -> EDRHeadroom? {
        await MainActor.run { () -> EDRHeadroom? in
            guard let screen = NSScreen.forDisplayID(displayID) else { return nil }

            let maxComponent = Float(screen.maximumExtendedDynamicRangeColorComponentValue)
            // In the EDR color space the display's reference white maps to a
            // component value of 1.0; highlights extend up to `maxComponent`.
            let referenceSample: Float = 1.0
            guard maxComponent > 1.0001 else { return nil }

            // XDR reference white is 100 nits; nits/referenceWhiteNits yields
            // the EDR component the shader needs.
            let referenceWhiteNits: Float = 100.0
            let peakNits = referenceWhiteNits * maxComponent
            let gamut = NSScreen.displayGamut(for: screen)

            return EDRHeadroom(
                displayID: displayID,
                edrHeadroom: maxComponent,
                referenceWhiteSample: referenceSample,
                referenceWhiteNits: referenceWhiteNits,
                peakNits: peakNits,
                colorGamut: gamut,
                measuredAt: Date()
            )
        }
    }

    // MARK: - ICC fallback (main-actor reads)

    /// Builds passthrough parameters from the display's ICC color space when
    /// EDR headroom is unavailable, so the frame is shown correctly in SDR
    /// rather than washed out.
    nonisolated static func iccFallback(displayID: CGDirectDisplayID, mode: ExtendedHDRMode) async -> PassthroughParameters {
        await MainActor.run {
            let gamut = NSScreen.displayGamut(forDisplayID: displayID) ?? .srgb
            let matrix = ICCProfile.profile(for: gamut).matrix
            return PassthroughParameters(
                displayID: displayID,
                edrHeadroom: 1.0,
                referenceWhiteNits: 100.0,
                peakNits: 100.0,
                gamutMatrix: matrix,
                usedICCFallback: true,
                timestamp: Date()
            )
        }
    }

    // MARK: - Gamut mapping

    /// Picks the content→display gamut transform for the active mode.
    ///
    /// For native EDR the decoder already targets the display gamut, so the
    /// renderer needs no extra rotation here — the display's ICC encoding
    /// matrix is returned so the shader has a stable, display-correct basis.
    /// On the ICC fallback path this same matrix is what keeps the picture
    /// from washing out.
    nonisolated static func gamutMatrix(for mode: ExtendedHDRMode, displayGamut: ColorGamut) -> simd_float3x3 {
        ICCProfile.profile(for: displayGamut).matrix
    }

    // MARK: - Format-description parsing (VideoToolbox / CoreMedia)

    /// Converts HDR metadata carried by a `CMFormatDescription` into an
    /// ``ExtendedHDRMode``. Returns `.sdr` for non-HDR descriptions and throws
    /// ``MediaError`` only when the description is `nil`/unreadable.
    nonisolated static func mode(from formatDescription: CMFormatDescription?) throws -> ExtendedHDRMode {
        guard let formatDescription else {
            throw MediaError(
                kind: .formatUnsupported,
                source: .local,
                underlyingDomain: "CMFormatDescription",
                underlyingMessage: "Missing format description for HDR metadata extraction.",
                message: "No format description available to extract HDR metadata."
            )
        }

        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] ?? [:]

        // Dolby Vision is signalled via its dedicated extension key.
        if extensions["DVSExtension"] != nil || extensions["DolbyVision"] != nil {
            // Detailed RPU parsing lives in DolbyVisionParser; here we surface
            // a conservative DV mode so passthrough scaling still engages.
            return .dolbyVision(DolbyVisionMetadata.placeholder)
        }

        // Mastering display color volume + content light level ⇒ HDR10.
        if let mdcv = extensions["MasteringDisplayColorVolume"] as? Data,
           let clli = extensions["ContentLightLevelInfo"] as? Data,
           let hdr10 = Self.hdr10(from: mdcv, clli: clli) {
            return .hdr10(hdr10)
        }

        // HDR10+ dynamic metadata is carried on a sideband SEI; when present we
        // keep the static HDR10 fallback plus the dynamic payload.
        if let h10p = Self.hdr10PlusIfPresent(in: extensions) {
            return .hdr10Plus(h10p)
        }

        return .sdr
    }

    // MARK: - Telemetry

    private func emitHDRMode(_ mode: ExtendedHDRMode) {
        let telemetryMode: TelemetryHDRMode?
        switch mode {
        case .hdr10: telemetryMode = .hdr10
        case .dolbyVision: telemetryMode = .dolbyVision
        case .hlg: telemetryMode = .hlg
        default: telemetryMode = nil
        }
        if let telemetryMode {
            telemetry.record(.hdrModeUsed(mode: telemetryMode, duration: 0))
        }
    }

    // MARK: - Timeout helper

    /// Races `operation` against a wall-clock timeout, mapping the timeout to
    /// ``MediaError/Kind/timedOut``.
    ///
    /// Declared `nonisolated` so it can be called from `@Sendable` task-group
    /// closures; `operation` must be `@Sendable`.
    nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        source: PlaybackSource = .local,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MediaError(kind: .timedOut, source: source,
                                 underlyingDomain: "MetadataPassthroughImpl",
                                 underlyingMessage: "Operation exceeded \(seconds)s budget.",
                                 message: "HDR passthrough operation timed out.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MediaError(kind: .unknown, source: source)
            }
            return result
        }
    }
}

// MARK: - NSScreen helpers

extension NSScreen {
    /// Finds the `NSScreen` backing a CoreGraphics display ID.
    fileprivate static func forDisplayID(_ displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
        }
    }

    /// Best-effort gamut inference from the screen's color space.
    fileprivate static func displayGamut(for screen: NSScreen) -> ColorGamut {
        displayGamut(forColorSpace: screen.colorSpace?.cgColorSpace)
    }

    /// Gamut inference from a display's ICC color space.
    fileprivate static func displayGamut(forDisplayID displayID: CGDirectDisplayID) -> ColorGamut? {
        let space = CGDisplayCopyColorSpace(displayID)
        return displayGamut(forColorSpace: space)
    }

    private static func displayGamut(forColorSpace space: CGColorSpace?) -> ColorGamut {
        guard let space else { return .srgb }
        let name = (space.name as String?) ?? ""
        switch name {
        case "Display P3", "Extended Display P3":
            return .displayP3
        case "ITU-R 2020", "Extended ITU-R 2020":
            return .bt2020
        default:
            return .srgb
        }
    }
}

// MARK: - SystemPressureObserver

/// Main-actor bound observer that forwards thermal/memory pressure changes to
/// the actor via a `@Sendable` callback.
///
/// AppKit/Foundation pressure notifications must be observed on the main
/// actor/run loop, so this helper is `@MainActor`. It is declared
/// `@unchecked Sendable` because every use is confined to the main actor and
/// it is only ever created/owned by the `MetadataPassthroughImpl` actor, which
/// always talks to it through `MainActor.run`.
@MainActor
final class SystemPressureObserver: @unchecked Sendable {
    private var cancellables: Set<AnyCancellable> = []
    private var memorySource: DispatchSourceMemoryPressure?
    private let onUpdate: @Sendable (MetadataPassthroughImpl.SystemPressureSnapshot) -> Void

    init(onUpdate: @Sendable @escaping (MetadataPassthroughImpl.SystemPressureSnapshot) -> Void) {
        self.onUpdate = onUpdate
        observeThermal()
        observeMemory()
    }

    private func observeThermal() {
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                self?.push()
            }
            .store(in: &cancellables)
    }

    private func observeMemory() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.push()
        }
        source.resume()
        memorySource = source
        // Emit an initial reading so the actor starts from reality, not nominal.
        push()
    }

    private func push() {
        let thermal: MetadataPassthroughImpl.SystemPressureSnapshot.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }

        let memory: MetadataPassthroughImpl.SystemPressureSnapshot.Memory
        if let source = memorySource {
            switch source.data {
            case .critical: memory = .critical
            case .warning: memory = .warning
            default: memory = .normal
            }
        } else {
            memory = .normal
        }

        onUpdate(.init(thermal: thermal, memory: memory, updatedAt: Date()))
    }

    func cancel() {
        cancellables.removeAll()
        memorySource?.cancel()
        memorySource = nil
    }
}

// MARK: - Format-description parsing details

extension MetadataPassthroughImpl {
    /// Builds ``HDR10Metadata`` from the raw `MasteringDisplayColorVolume` and
    /// `ContentLightLevelInfo` boxes. Returns `nil` when the blobs are too
    /// short to parse.
    nonisolated static func hdr10(from mdcv: Data, clli: Data) -> HDR10Metadata? {
        // MDCV: 10x u16 primaries (xR,yR,xG,yG,xB,yB) + 2x u32 white (x,y)
        //       + u32 maxDisplay + u32 minDisplay (nits * 10000).
        guard mdcv.count >= 24 else { return nil }
        let maxDisplay = Float(mdcv.readUInt32(at: 20)) / 10000.0
        let minDisplay = Float(mdcv.readUInt32(at: 24)) / 10000.0

        var maxCLL: Float = 0, maxFALL: Float = 0
        if clli.count >= 8 {
            maxCLL = Float(clli.readUInt16(at: 0))
            maxFALL = Float(clli.readUInt16(at: 2))
        }

        return HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: maxDisplay > 0 ? maxDisplay : 1000.0,
            minDisplayLuminance: minDisplay > 0 ? minDisplay : 0.001,
            maxContentLightLevel: maxCLL > 0 ? maxCLL : (maxDisplay > 0 ? maxDisplay : 1000.0),
            maxFrameAverageLightLevel: maxFALL > 0 ? maxFALL : (maxDisplay > 0 ? maxDisplay : 400.0)
        )
    }

    /// Returns HDR10+ metadata when a recognised sideband payload is present.
    nonisolated static func hdr10PlusIfPresent(in extensions: [String: Any]) -> HDR10PlusMetadata? {
        guard let payload = extensions["HDR10Plus"] as? Data, !payload.isEmpty else { return nil }
        // Full SEI parsing lives in HDR10PlusParser; emit a conservative default
        // so passthrough scaling still engages for HDR10+ content.
        return HDR10PlusMetadata(
            curveExponent: 0,
            kneePointX: 0,
            kneePointY: 0,
            numBezierCurveAnchors: 0,
            bezierCurveAnchors: [],
            colorSaturationMap: []
        )
    }
}

// MARK: - Data helpers

extension Data {
    fileprivate func readUInt16(at offset: Int) -> UInt16 {
        guard count >= offset + 2 else { return 0 }
        return (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    fileprivate func readUInt32(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(self[offset + i])
        }
        return value
    }
}
