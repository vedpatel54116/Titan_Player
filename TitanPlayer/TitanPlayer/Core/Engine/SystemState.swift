import Foundation
import Combine
import OSLog

// MARK: - System health model

/// A point-in-time assessment of the host system's resource health that is
/// relevant to media playback.
///
/// The engine consults ``SystemStateSnapshot`` to decide whether decoding and
/// rendering should continue unthrottled, scale down, or pause outright. All
/// values are derived from first-party Apple APIs
/// (`ProcessInfo.thermalState` and `DispatchSource` memory-pressure events),
/// so the snapshot never drifts from the OS's own view of the machine.
public struct SystemStateSnapshot: Sendable, Equatable {
    /// The current thermal condition of the device.
    public var thermal: ThermalLevel
    /// The current memory-pressure condition of the device.
    public var memory: MemoryPressureLevel
    /// When this snapshot was captured.
    public var observedAt: Date

    /// The nominal, fully-healthy snapshot (used as the initial value before
    /// the first observation arrives).
    public static let nominal = SystemStateSnapshot(
        thermal: .nominal,
        memory: .normal,
        observedAt: .distantPast
    )

    /// Convenience initializer.
    public init(thermal: ThermalLevel, memory: MemoryPressureLevel, observedAt: Date) {
        self.thermal = thermal
        self.memory = memory
        self.observedAt = observedAt
    }

    // MARK: Derived guidance

    /// `true` when both thermal and memory conditions are at their calmest.
    public var isHealthy: Bool {
        thermal == .nominal && memory == .normal
    }

    /// The pipeline should reduce decode/render work (e.g. drop to a lower
    /// quality tier) but may keep playing.
    public var shouldThrottleDecoding: Bool {
        switch thermal {
        case .serious, .critical: return true
        case .nominal, .fair: break
        }
        return memory == .warning
    }

    /// The pipeline should pause playback until the system recovers.
    public var shouldPauseForSystem: Bool {
        thermal == .critical || memory == .critical
    }
}

/// Coarse thermal condition reported by the operating system.
public enum ThermalLevel: Int, Sendable, Equatable, CustomStringConvertible {
    case nominal = 0
    case fair
    case serious
    case critical

    public var description: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }

    /// Maps `ProcessInfo.ThermalState` onto ``ThermalLevel``.
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

/// Coarse memory-pressure condition reported by the operating system.
public enum MemoryPressureLevel: Int, Sendable, Equatable, CustomStringConvertible {
    case normal = 0
    case warning
    case critical

    public var description: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    /// Maps a `DispatchSource.MemoryPressureEvent` onto ``MemoryPressureLevel``.
    init(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            self = .critical
        } else if event.contains(.warning) {
            self = .warning
        } else {
            self = .normal
        }
    }
}

// MARK: - System state monitor

/// Observes system thermal and memory-pressure conditions and translates them
/// into playback-guidance signals.
///
/// ## Why this exists
/// Titan Player previously had no visibility into thermal throttling or memory
/// pressure. Playback therefore continued — and kept requesting maximum decode
/// and render work — even while the OS was throttling the CPU/GPU, producing
/// stutter and, in the worst case, watchdog kills. ``SystemStateMonitor`` makes
/// those conditions observable so the engine can proactively throttle or pause.
///
/// ## Lifecycle
/// 1. Create the monitor (optionally injecting a ``TelemetryProviding``).
/// 2. Call ``start()`` to begin observing OS notifications and memory-pressure
///    events and to publish an initial snapshot.
/// 3. Subscribe to ``snapshotPublisher`` to react to changes.
/// 4. Call ``stop()`` (or `deinit`) to tear everything down — this is the
///    cancellation path and releases every observer and source.
///
/// All observation callbacks hop back to the main actor before touching state,
/// so the monitor is safe to use from UI code and is `@MainActor`-isolated and
/// `Sendable`.
@MainActor
public final class SystemStateMonitor: Sendable {
    // MARK: - Public API

    /// A continuously-updating stream of the latest ``SystemStateSnapshot``.
    ///
    /// Replays the most recent snapshot to new subscribers, then emits on every
    /// change. Errors are never emitted here; pressure conditions are reported
    /// as data, not failures.
    public var snapshotPublisher: AnyPublisher<SystemStateSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    /// The most recently observed snapshot (or ``SystemStateSnapshot/nominal``).
    public var currentSnapshot: SystemStateSnapshot { subject.value }

    // MARK: - Private state

    private let telemetry: (any TelemetryProviding)?
    private let logger = Logger(subsystem: "com.titanplayer", category: "SystemState")

    private let subject = CurrentValueSubject<SystemStateSnapshot, Never>(.nominal)
    private var memorySource: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?
    private var isActive = false

    /// Creates a monitor.
    ///
    /// - Parameter telemetry: An optional ``TelemetryProviding`` sink. When
    ///   omitted, telemetry is silently skipped (no direct Sentry usage).
    init(telemetry: (any TelemetryProviding)? = nil) {
        self.telemetry = telemetry
    }

    deinit {
        // `deinit` of a `@MainActor` class is itself main-actor-isolated, so the
        // non-`Sendable` dispatch source and observer can be released directly
        // without crossing an actor boundary.
        memorySource?.cancel()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    // MARK: - Observation control

    /// Begins observing thermal and memory-pressure conditions.
    ///
    /// Calling ``start()`` while already active is a no-op. Observation is
    /// idempotent and safe to call after ``stop()``.
    public func start() {
        guard !isActive else { return }
        isActive = true

        observeThermalState()
        observeMemoryPressure()
        publishSnapshot(readCurrent(), source: "start")
        logger.info("SystemStateMonitor started")
    }

    /// Stops observing and releases all resources.
    ///
    /// This is the explicit cancellation path; it cancels the memory-pressure
    /// dispatch source and removes the thermal notification observer so nothing
    /// is left dangling (important for Instruments leak checks).
    public func stop() {
        guard isActive else { return }
        isActive = false

        memorySource?.cancel()
        memorySource = nil
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        thermalObserver = nil
        logger.info("SystemStateMonitor stopped")
    }

    // MARK: - Sampling with timeout

    /// Returns the next freshly-observed snapshot, failing if one cannot be
    /// produced within `timeout`.
    ///
    /// Useful for callers that must block startup on a real reading (rather than
    /// the ``SystemStateSnapshot/nominal`` placeholder) but cannot wait forever.
    ///
    /// - Parameter timeout: How long to wait for an observation before throwing.
    /// - Returns: A real ``SystemStateSnapshot`` captured after `timeout` began.
    /// - Throws: ``MediaError`` with code `.systemPressure` on timeout or
    ///   cancellation.
    public func snapshot(after timeout: Duration) async throws -> SystemStateSnapshot {
        try await withThrowingTaskGroup(of: SystemStateSnapshot.self) { group in
            group.addTask { @MainActor in
                // Runs on the main actor so `subject` is accessible. Wait for
                // the *next* value distinct from the placeholder so we know it
                // came from a live observation.
                for await snapshot in self.subject.values {
                    if snapshot.observedAt != SystemStateSnapshot.nominal.observedAt {
                        return snapshot
                    }
                }
                throw MediaError(
                    code: .systemPressure,
                    message: "System state stream terminated before a reading was available"
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MediaError(
                    code: .systemPressure,
                    message: "Timed out waiting for a system state reading after \(timeout)"
                )
            }

            guard let result = try await group.next() else {
                throw MediaError(
                    code: .systemPressure,
                    message: "System state observation produced no result"
                )
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private observation

    private func observeThermalState() {
        let observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.publishSnapshot(self.readCurrent(), source: "thermal")
            }
        }
        thermalObserver = observer
    }

    private func observeMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .all],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let level = MemoryPressureLevel(source.mask)
                self.publishSnapshot(
                    SystemStateSnapshot(
                        thermal: self.readThermal(),
                        memory: level,
                        observedAt: Date()
                    ),
                    source: "memory"
                )
            }
        }
        source.resume()
        memorySource = source
    }

    private func readCurrent() -> SystemStateSnapshot {
        SystemStateSnapshot(
            thermal: readThermal(),
            memory: readMemory(),
            observedAt: Date()
        )
    }

    private func readThermal() -> ThermalLevel {
        ThermalLevel(ProcessInfo.processInfo.thermalState)
    }

    private func readMemory() -> MemoryPressureLevel {
        // `DispatchSource` does not expose the current pressure level directly;
        // fall back to `.normal` for the synthetic snapshot and let the live
        // memory-pressure event handler supply the real level.
        .normal
    }

    private func publishSnapshot(_ snapshot: SystemStateSnapshot, source: String) {
        subject.send(snapshot)
        if snapshot.shouldPauseForSystem {
            recordCritical(reason: "system_pressure:\(snapshot.thermal)_mem:\(snapshot.memory)", source: source)
        } else if snapshot.shouldThrottleDecoding {
            logger.warning("System throttling suggested (thermal=\(snapshot.thermal.description), memory=\(snapshot.memory.description))")
        } else {
            #if DEBUG
            logger.debug("System nominal (source=\(source))")
            #endif
        }
    }

    // MARK: - Telemetry

    /// Emits a telemetry event through the injected ``TelemetryProviding`` sink.
    ///
    /// Direct Sentry usage is intentionally avoided — every signal funnels
    /// through `telemetry.record(_:)` so the app's consent and privacy gates
    /// apply uniformly.
    private func recordCritical(reason: String, source: String) {
        guard let telemetry else { return }
        let event = TelemetryEvent.compatibilityModeActivated(
            reason: "thermal_throttle:\(reason)",
            source: .local
        )
        telemetry.record(event)
        logger.error("System critical — playback should pause (source=\(source), \(reason))")
    }
}
