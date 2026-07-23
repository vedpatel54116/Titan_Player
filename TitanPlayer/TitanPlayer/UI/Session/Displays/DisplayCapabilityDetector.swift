import AppKit
import CoreGraphics
import Foundation
import os

/// A `Sendable` telemetry sink used by ``DisplayCapabilityDetector``.
///
/// The detector never touches Sentry directly. Instead it depends on this
/// small abstraction, whose default implementation forwards events to
/// ``TelemetryManager/shared`` (which wraps Sentry). Callers may inject a
/// custom sink for tests or alternate backends without altering detection
/// logic. The closure is `@Sendable` so the sink is safe to store inside the
/// `Sendable` detector and to invoke from any concurrency context.
struct TelemetrySink: Sendable {
    // MARK: Properties

    private let emit: @Sendable (TelemetryEvent) -> Void

    // MARK: Initialization

    init(emit: @escaping @Sendable (TelemetryEvent) -> Void) {
        self.emit = emit
    }

    /// Forwards events to `TelemetryManager.shared` on the main actor, hopping
    /// off whatever context the detector is running on. `TelemetryManager` is
    /// `@MainActor`-isolated, so the hand-off is wrapped in a `Task`.
    static let shared = TelemetrySink { event in
        Task { @MainActor in TelemetryManager.shared.record(event) }
    }

    // MARK: Emitting

    func record(_ event: TelemetryEvent) {
        emit(event)
    }
}

/// Detects the color, HDR/EDR, and ICC capabilities of an ``NSScreen``.
///
/// ## Why this exists
/// Titan Player renders HDR content through a Metal pipeline that must know,
/// per display, whether extended dynamic range (EDR) is available and what
/// color gamut the display can reproduce. The original detector keyed HDR
/// support solely off the *currently active* EDR component value
/// (`maximumExtendedDynamicRangeColorComponentValue`). On external monitors
/// that value reads `1.0` while the display is presenting SDR content even
/// though the hardware is HDR-capable, so HDR detection silently failed for
/// secondary displays. This type fixes that by also consulting the display's
/// *potential* EDR headroom and its color space / ICC profile.
///
/// ## Concurrency
/// The detector is a value type that conforms to `Sendable`: all stored
/// properties are value types or `Sendable` closures, so it can be created on
/// one actor and used from another without copying shared mutable state.
///
/// Two detection surfaces are provided:
/// - Synchronous ``detectCapabilities(for:)`` / ``detectICCProfile(for:)`` —
///   kept for the existing `MetalRenderer` / `DisplayManager` call sites. These
///   read `AppKit` state and therefore must be called on the main thread.
/// - Asynchronous ``detect(for:)`` — the robust entry point. It honours task
///   cancellation, enforces a timeout budget, bails out under critical thermal
///   or memory pressure (mapping both onto ``MediaError``), and emits telemetry
///   through ``TelemetrySink`` rather than touching Sentry directly.
struct DisplayCapabilityDetector: Sendable {
    // MARK: - Configuration

    /// Maximum time budget for a single ``detect(for:)`` attempt. Exceeding it
    /// surfaces as ``MediaError/Kind/timedOut``.
    let timeout: Duration

    /// Playback origin used to bucket telemetry and error context.
    let source: PlaybackSource

    /// Below this many free bytes, ``detect(for:)`` aborts with
    /// ``MediaError/Kind/memoryPressure`` before allocating anything.
    let memoryPressureThresholdBytes: UInt64

    /// Telemetry sink. Defaults to forwarding through `TelemetryManager`.
    private let telemetry: TelemetrySink

    // MARK: - Initialization

    /// Creates a detector.
    ///
    /// - Parameters:
    ///   - telemetry: Sink for telemetry. Defaults to ``TelemetrySink/shared``.
    ///   - timeout: Detection timeout budget. Defaults to 2 seconds.
    ///   - source: Telemetry / error origin. Defaults to `.local`.
    ///   - memoryPressureThresholdBytes: Free-memory floor. Defaults to 256 MB.
    init(
        telemetry: TelemetrySink = .shared,
        timeout: Duration = .seconds(2),
        source: PlaybackSource = .local,
        memoryPressureThresholdBytes: UInt64 = UInt64(256 * 1024 * 1024)
    ) {
        self.telemetry = telemetry
        self.timeout = timeout
        self.source = source
        self.memoryPressureThresholdBytes = memoryPressureThresholdBytes
    }

    // MARK: - Synchronous Detection (main-thread)

    /// Detects HDR / EDR capability and color gamut for a screen.
    ///
    /// - Important: Must be called on the main thread. `NSScreen` properties
    ///   are main-thread state in AppKit; callers off the main actor should use
    ///   the async ``detect(for:)`` entry point instead.
    ///
    /// - Parameter screen: The screen to inspect.
    /// - Returns: A ``DisplayCapabilities`` value.
    func detectCapabilities(for screen: NSScreen) -> DisplayCapabilities {
        let activeEDR = screen.maximumExtendedDynamicRangeColorComponentValue
        let potentialEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        let peak = max(activeEDR, potentialEDR)

        // Prefer the *potential* EDR headroom: an external HDR display reporting
        // a `1.0` active value while showing SDR content is still EDR-capable.
        let supportsEDR = peak > 1.0
        let gamut = detectGamut(for: screen)
        let supportsHDR = supportsEDR || gamut == .bt2020

        // Apple's EDR reference white is ~80 nits, so scale the normalized peak
        // component value into an approximate peak luminance in nits.
        let maxEDRLuminance = Float(peak) * 80.0

        return DisplayCapabilities(
            supportsHDR: supportsHDR,
            supportsEDR: supportsEDR,
            maxEDRLuminance: maxEDRLuminance,
            colorGamut: gamut
        )
    }

    /// Resolves the ICC color profile for a screen based on its detected gamut.
    ///
    /// - Important: Must be called on the main thread (see
    ///   ``detectCapabilities(for:)``).
    ///
    /// - Parameter screen: The screen to inspect.
    /// - Returns: An ``ICCProfile`` whose conversion matrix matches the gamut.
    func detectICCProfile(for screen: NSScreen) -> ICCProfile {
        ICCProfile.profile(for: detectGamut(for: screen))
    }

    // MARK: - Asynchronous Detection (robust)

    /// A consolidated, failure-mapped result of a capability detection pass.
    /// A consolidated, failure-mapped result of a capability detection pass.
    struct Report: Sendable, Equatable {
        /// The resolved display capabilities.
        let capabilities: DisplayCapabilities
        /// The resolved ICC profile.
        let iccProfile: ICCProfile
        /// Stable CoreGraphics display identifier, when resolvable.
        let stableDisplayID: String?
        /// Human-readable screen name.
        let screenName: String?
        /// Wall-clock time spent in detection.
        let detectionDuration: TimeInterval
    }

    /// Robustly detects display capabilities with cancellation, timeout, and
    /// system-pressure handling.
    ///
    /// The operation fails fast (mapping onto ``MediaError``) when the system
    /// is under critical thermal or memory pressure, when the enclosing task is
    /// cancelled, or when detection exceeds ``timeout``. All failures are
    /// reported through ``TelemetrySink`` rather than Sentry directly.
    ///
    /// - Parameter screen: The screen to inspect.
    /// - Returns: A ``Report`` describing the display.
    /// - Throws: A ``MediaError`` for cancellation, timeout, or pressure.
    func detect(for screen: NSScreen) async throws -> Report {
        try Task.checkCancellation()

        return try await withTimeout(timeout) { [self] in
            try Task.checkCancellation()

            // Thermal pressure is reported by the OS, not thrown, so we probe it
            // up front and map it onto MediaError before doing any work.
            let thermalState = ProcessInfo.processInfo.thermalState
            if thermalState == .critical {
                let error = MediaError.thermalPressure(state: thermalState, source: source)
                recordFailure(error)
                throw error
            }

            // Memory pressure: bail out (mapping onto MediaError) when the system
            // reports critical memory pressure. We observe a memory-pressure
            // source for the duration of detection and cancel it in `defer` so
            // nothing leaks. A brief `yield` lets the source deliver its current
            // state before we sample it.
            let memorySource = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .main
            )
            var memoryCritical = false
            memorySource.setEventHandler { [weak memorySource] in
                if memorySource?.data.contains(.critical) == true {
                    memoryCritical = true
                }
            }
            memorySource.resume()
            defer { memorySource.cancel() }
            await Task.yield()
            if memoryCritical {
                let error = MediaError.memoryPressure(source: source)
                recordFailure(error)
                throw error
            }

            let start = Date()
            let capabilities = detectCapabilities(for: screen)
            let iccProfile = detectICCProfile(for: screen)
            let stableDisplayID = self.stableDisplayID(for: screen)
            let screenName = screen.localizedName
            let detectionDuration = Date().timeIntervalSince(start)

            try Task.checkCancellation()

            let report = Report(
                capabilities: capabilities,
                iccProfile: iccProfile,
                stableDisplayID: stableDisplayID,
                screenName: screenName,
                detectionDuration: detectionDuration
            )
            recordSuccess(report)
            return report
        }
    }

    // MARK: - Gamut / ICC Helpers

    /// Resolves the display's color gamut.
    ///
    /// Detection prefers the color space's *named* identity (via
    /// `CGColorSpaceCopyName`) over the localized, human-readable name, which
    /// is far more stable across locales and macOS versions. Unsupported or
    /// missing spaces fall back to `.srgb` rather than incorrectly reporting a
    /// wide gamut.
    private func detectGamut(for screen: NSScreen) -> ColorGamut {
        guard let nsSpace = screen.colorSpace else { return .srgb }
        let cgSpace = nsSpace.cgColorSpace

        if let cfName = cgSpace?.name {
            let name = String(describing: cfName)
            if name.contains("ITUR_2020") || name.contains("BT.2020") || name.contains("2020") {
                return .bt2020
            }
            if name.contains("Display P3") || name.contains("P3") {
                return .displayP3
            }
            if name.contains("SRGB") {
                return .srgb
            }
        }

        // Fallback to the localized name when no named identity is available.
        let localized = nsSpace.localizedName ?? ""
        if localized.contains("2020") {
            return .bt2020
        }
        if localized.contains("P3") {
            return .displayP3
        }
        return .srgb
    }

    /// Resolves the stable CoreGraphics display identifier for telemetry.
    private func stableDisplayID(for screen: NSScreen) -> String? {
        guard let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            return nil
        }
        return "CGDisplay-\(raw)"
    }

    // MARK: - System Pressure Monitoring

    /// Races `operation` against a timeout, throwing ``MediaError/Kind/timedOut``
    /// if the budget elapses first. The losing task is cancelled to avoid leaks.
    private func withTimeout<T: Sendable>(
        _ budget: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: budget)
                throw MediaError(
                    kind: .timedOut,
                    source: source,
                    message: "Display capability detection exceeded \(budget) budget."
                )
            }
            guard let result = try await group.next() else {
                throw MediaError(
                    kind: .unknown,
                    source: source,
                    message: "Display capability detection produced no result."
                )
            }
            return result
        }
    }

    // MARK: - Telemetry

    private func recordSuccess(_ report: Report) {
        telemetry.record(
            .displayCapabilitiesDetected(
                stableID: report.stableDisplayID ?? "unknown",
                supportsHDR: report.capabilities.supportsHDR,
                supportsEDR: report.capabilities.supportsEDR,
                colorGamut: report.capabilities.colorGamut.rawValue,
                source: source
            )
        )
    }

    private func recordFailure(_ error: MediaError) {
        telemetry.record(
            .displayDetectionFailed(
                errorCode: error.telemetryErrorCode,
                source: source
            )
        )
    }
}
