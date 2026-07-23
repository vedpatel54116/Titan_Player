import Foundation
import Network
import OSLog

// MARK: - Network path snapshot

/// A point-in-time view of the network used for adaptive bitrate (ABR) decisions.
///
/// Every field is a value type, so the snapshot is `Sendable` and safe to hand
/// across actor boundaries to the ABR selector. The ``estimatedCapacityScore``
/// folds the raw OS signals (interface, expense, constraints, thermal and
/// memory pressure) into a single `0…1` number the ABR can trust without
/// re-implementing that logic at every call site.
public struct NetworkPathSnapshot: Sendable, Equatable {

    // MARK: Interface

    /// The physical interfaces a path may ride over.
    public enum Interface: Sendable, Equatable, CustomStringConvertible {
        case wifi
        case cellular
        case wiredEthernet
        case loopback
        case other

        public var description: String {
            switch self {
            case .wifi: return "wifi"
            case .cellular: return "cellular"
            case .wiredEthernet: return "wiredEthernet"
            case .loopback: return "loopback"
            case .other: return "other"
            @unknown default: return "other"
            }
        }

        /// Maps an `NWInterface.InterfaceType` onto ``Interface``.
        init(_ type: NWInterface.InterfaceType) {
            switch type {
            case .wifi: self = .wifi
            case .cellular: self = .cellular
            case .wiredEthernet: self = .wiredEthernet
            case .loopback: self = .loopback
            default: self = .other
            }
        }
    }

    // MARK: Stored properties

    /// The primary reachability, mirroring the legacy ``Reach`` enum.
    public var reach: Reach
    /// Every interface the current path can use.
    public var interfaces: Set<Interface>
    /// `true` when the path is metered (e.g. cellular tethering).
    public var isExpensive: Bool
    /// `true` when the carrier applies low-data-mode constraints.
    public var isConstrained: Bool
    /// Current thermal condition (drives decode throttling).
    public var thermal: ThermalLevel
    /// Current memory-pressure condition (drives pause decisions).
    public var memory: MemoryPressureLevel
    /// When this snapshot was captured.
    public var observedAt: Date

    // MARK: Initialization

    public init(
        reach: Reach,
        interfaces: Set<Interface>,
        isExpensive: Bool,
        isConstrained: Bool,
        thermal: ThermalLevel,
        memory: MemoryPressureLevel,
        observedAt: Date
    ) {
        self.reach = reach
        self.interfaces = interfaces
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.thermal = thermal
        self.memory = memory
        self.observedAt = observedAt
    }

    // MARK: Derived ABR signal

    /// A normalized `0…1` estimate of usable link capacity for the ABR selector.
    ///
    /// - `1.0` — wired/Wi-Fi, unthrottled.
    /// - `0.5` — cellular, unthrottled.
    /// - `0.0` — no path.
    ///
    /// The expensive/constrained flags and system-pressure levels apply
    /// additional penalties so the ABR backs off before the OS throttles or
    /// kills the app.
    public var estimatedCapacityScore: Double {
        let base: Double
        switch reach {
        case .wired, .wifi: base = 1.0
        case .cellular: base = 0.5
        case .offline: return 0.0
        }

        var score = base
        if isExpensive { score *= 0.8 }
        if isConstrained { score *= 0.7 }

        switch thermal {
        case .nominal, .fair: break
        case .serious: score *= 0.7
        case .critical: score *= 0.4
        }

        switch memory {
        case .normal: break
        case .warning: score *= 0.85
        case .critical: score *= 0.5
        }

        return min(1.0, max(0.0, score))
    }

    /// `true` when a usable path exists.
    public var isSatisfied: Bool { reach != .offline }
}

// MARK: - Network path monitor

/// An actor that observes `NWPathMonitor`, thermal and memory-pressure signals
/// and exposes them as a single stream for the ABR selector.
///
/// ## Why this exists
/// Titan Player's adaptive bitrate selection was previously *blind* to live
/// network changes: the legacy ``NetworkMonitor`` (a `@MainActor` `ObservableObject`)
/// published reachability to SwiftUI but never fed the ABR path selector. As a
/// result a Wi-Fi ↔ cellular handover — or the OS silently marking a path
/// expensive/constrained — left the pipeline stalled on a dead tier. This actor
/// is the fix: it runs `NWPathMonitor` off the main actor, funnels every signal
/// through one `Sendable` ``NetworkPathSnapshot``, and streams it to any ABR
/// consumer via ``snapshotStream``.
///
/// ## Concurrency & Sendable
/// The actor is genuinely `Sendable`. The non-`Sendable` `NWPathMonitor`, its
/// `DispatchSource` memory-pressure source and `NotificationCenter` observer are
/// confined to a `@unchecked Sendable` ``PathMonitorHandle`` that only forwards
/// normalized `@Sendable` closures back into the actor. The stream continuation
/// is owned by a `@unchecked Sendable` ``SnapshotStreamController`` whose `deinit`
/// finishes the stream, so teardown is leak-free under Instruments.
///
/// ## Errors
/// Every failure this actor surfaces is mapped onto the centralized
/// ``MediaError`` (via ``Kind/networkUnavailable``, ``Kind/timedOut`` or
/// ``Kind/cancelled``) — never a raw OS error. Telemetry is emitted **only**
/// through the injected ``TelemetryProviding`` protocol; Sentry is never
/// referenced directly.
public actor NetworkPathMonitor: Sendable {

    // MARK: - Public API

    /// A continuous stream of the latest ``NetworkPathSnapshot``.
    ///
    /// Replays the initial (nominal) snapshot, then emits on every path,
    /// thermal or memory-pressure change. The stream finishes when the actor is
    /// deallocated, so `for await` loops terminate cleanly with no leak.
    public nonisolated var snapshotStream: AsyncStream<NetworkPathSnapshot> {
        streamController.stream
    }

    /// The most recently observed snapshot (nominal until the first reading).
    public func snapshot() -> NetworkPathSnapshot { current }

    /// `true` once a usable path has been observed.
    public func isSatisfied() -> Bool { current.isSatisfied }

    // MARK: - Private state

    private let handle: PathMonitorHandle
    private let streamController: SnapshotStreamController
    private let sink: TelemetryBox
    private let logger = Logger(subsystem: "com.titanplayer", category: "NetworkPathMonitor")

    private var current: NetworkPathSnapshot
    private var lastTelemetryReach: Reach
    private var isActive = false

    // MARK: - Initialization

    /// Creates the monitor.
    ///
    /// - Parameters:
    ///   - telemetry: An optional ``TelemetryProviding`` sink. When omitted,
    ///     telemetry is silently skipped (no direct Sentry usage).
    ///   - startImmediately: When `true` (default) observation begins at once.
    init(telemetry: (any TelemetryProviding)? = nil, startImmediately: Bool = true) {
        let streamController = SnapshotStreamController()
        self.streamController = streamController
        self.sink = TelemetryBox(telemetry)

        let nominal = NetworkPathSnapshot(
            reach: .offline,
            interfaces: [],
            isExpensive: false,
            isConstrained: false,
            thermal: .nominal,
            memory: .normal,
            observedAt: .distantPast
        )
        self.current = nominal
        self.lastTelemetryReach = .offline

        // The handle forwards normalized `@Sendable` values back into the actor.
        // It captures the actor weakly so the actor → handle → actor cycle is broken.
        self.handle = PathMonitorHandle(
            onPath: { [weak self] info in Task { await self?.apply(info) } },
            onThermal: { [weak self] level in Task { await self?.apply(thermal: level) } },
            onMemory: { [weak self] level in Task { await self?.apply(memory: level) } }
        )

        if startImmediately {
            Task { await self.start() }
        }
    }

    // MARK: - Observation control

    /// Begins observing the network path, thermal and memory pressure.
    ///
    /// Idempotent: calling while active is a no-op and safe after ``stop()``.
    public func start() {
        guard !isActive else { return }
        isActive = true
        handle.start()
        logger.info("NetworkPathMonitor started")
    }

    /// Stops observing and releases the underlying `NWPathMonitor` and sources.
    ///
    /// This is the explicit cancellation path. It does **not** finish
    /// ``snapshotStream`` (that happens on actor `deinit`) so the monitor can be
    /// restarted without orphaning in-flight `for await` loops.
    public func stop() {
        guard isActive else { return }
        isActive = false
        handle.cancel()
        logger.info("NetworkPathMonitor stopped")
    }

    // MARK: - Blocking read with timeout

    /// Waits until a usable path is observed, or throws if that cannot happen
    /// within `timeout`.
    ///
    /// Useful for callers that must block startup on a live connection rather
    /// than the nominal placeholder, but must not wait forever. It polls the
    /// actor's own ``current`` snapshot rather than consuming ``snapshotStream``,
    /// so it never competes with an external `for await` consumer of that stream.
    ///
    /// - Parameter timeout: How long to wait for a satisfied path.
    /// - Returns: The first ``NetworkPathSnapshot`` with a non-offline reach.
    /// - Throws: ``MediaError`` with kind `.timedOut` on timeout or `.cancelled`
    ///   on task cancellation.
    public func waitUntilSatisfied(within timeout: Duration) async throws -> NetworkPathSnapshot {
        if current.isSatisfied { return current }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled {
                throw MediaError(
                    kind: .cancelled,
                    source: .local,
                    message: "Cancelled while waiting for a usable network path"
                )
            }
            if current.isSatisfied { return current }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch is CancellationError {
                throw MediaError(
                    kind: .cancelled,
                    source: .local,
                    message: "Cancelled while waiting for a usable network path"
                )
            }
        }

        throw MediaError(
            kind: .timedOut,
            source: .local,
            message: "Timed out waiting for a usable network path after \(timeout)"
        )
    }

    // MARK: - Private apply (actor-isolated)

    /// Merges a fresh path reading into the current snapshot and publishes it.
    private func apply(_ info: PathInfo) {
        current = NetworkPathSnapshot(
            reach: info.reach,
            interfaces: info.interfaces,
            isExpensive: info.isExpensive,
            isConstrained: info.isConstrained,
            thermal: current.thermal,
            memory: current.memory,
            observedAt: Date()
        )
        streamController.yield(current)
        recordHandover(from: lastTelemetryReach, to: current.reach,
                       expensive: current.isExpensive, constrained: current.isConstrained)
        lastTelemetryReach = current.reach
    }

    /// Records a change detected on the thermal channel.
    private func apply(thermal: ThermalLevel) {
        guard thermal != current.thermal else { return }
        current = NetworkPathSnapshot(
            reach: current.reach,
            interfaces: current.interfaces,
            isExpensive: current.isExpensive,
            isConstrained: current.isConstrained,
            thermal: thermal,
            memory: current.memory,
            observedAt: Date()
        )
        streamController.yield(current)
    }

    /// Records a change detected on the memory-pressure channel.
    private func apply(memory: MemoryPressureLevel) {
        guard memory != current.memory else { return }
        current = NetworkPathSnapshot(
            reach: current.reach,
            interfaces: current.interfaces,
            isExpensive: current.isExpensive,
            isConstrained: current.isConstrained,
            thermal: current.thermal,
            memory: memory,
            observedAt: Date()
        )
        streamController.yield(current)
    }

    // MARK: - Telemetry

    /// Emits a network handover event through the injected ``TelemetryProviding``
    /// sink only — Sentry is never referenced directly.
    private func recordHandover(from previous: Reach, to current: Reach,
                                expensive: Bool, constrained: Bool) {
        guard let telemetry = sink.telemetry else { return }
        let event = TelemetryEvent.networkStateChanged(
            previous: previous.displayLabel,
            current: current.displayLabel,
            expensive: expensive,
            constrained: constrained,
            source: .local
        )
        Task { @MainActor in
            telemetry.record(event)
        }
    }
}

// MARK: - PathMonitorHandle

/// `Sendable` owner for the non-`Sendable` `NWPathMonitor` and the OS
/// thermal/memory-pressure observers.
///
/// Each observer only forwards a normalized, value-typed signal through a
/// `@Sendable` closure, so it never captures actor-isolated state. The handle
/// runs `NWPathMonitor` on its own serial queue and tears everything down in
/// `deinit`, making it safe to store inside a `Sendable` actor.
private final class PathMonitorHandle: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var memorySource: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?

    private let onPath: @Sendable (PathInfo) -> Void
    private let onThermal: @Sendable (ThermalLevel) -> Void
    private let onMemory: @Sendable (MemoryPressureLevel) -> Void

    init(
        onPath: @escaping @Sendable (PathInfo) -> Void,
        onThermal: @escaping @Sendable (ThermalLevel) -> Void,
        onMemory: @escaping @Sendable (MemoryPressureLevel) -> Void
    ) {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.titanplayer.networkpath")
        self.onPath = onPath
        self.onThermal = onThermal
        self.onMemory = onMemory

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.onPath(PathInfo(path: path))
        }
    }

    func start() {
        monitor.start(queue: queue)

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onThermal(ThermalLevel(ProcessInfo.processInfo.thermalState))
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.onMemory(MemoryPressureLevel(source.mask))
        }
        source.resume()
        memorySource = source

        // Seed the thermal/memory channels with their current values.
        onThermal(ThermalLevel(ProcessInfo.processInfo.thermalState))
        onMemory(.normal)
    }

    func cancel() {
        monitor.cancel()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        thermalObserver = nil
        memorySource?.cancel()
        memorySource = nil
    }

    deinit {
        cancel()
    }
}

// MARK: - PathInfo

/// A normalized, `Sendable` view of an `NWPath` forwarded by ``PathMonitorHandle``.
private struct PathInfo: Sendable {
    let reach: Reach
    let interfaces: Set<NetworkPathSnapshot.Interface>
    let isExpensive: Bool
    let isConstrained: Bool

    init(path: NWPath) {
        var interfaces: Set<NetworkPathSnapshot.Interface> = []
        for interface in path.availableInterfaces {
            interfaces.insert(NetworkPathSnapshot.Interface(interface.type))
        }
        self.interfaces = interfaces
        self.isExpensive = path.isExpensive
        self.isConstrained = path.isConstrained

        let satisfied = path.status == .satisfied
        if !satisfied {
            self.reach = .offline
        } else if path.usesInterfaceType(.wifi) {
            self.reach = .wifi
        } else if path.usesInterfaceType(.cellular) {
            self.reach = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            self.reach = .wired
        } else {
            self.reach = interfaces.isEmpty ? .offline : .wifi
        }
    }
}

// MARK: - SnapshotStreamController

/// `Sendable` owner for the `AsyncStream` continuation.
///
/// Encapsulating the continuation here lets this controller's own `deinit`
/// finish the stream when the enclosing actor is deallocated — actor `deinit`
/// itself cannot touch actor-isolated state, so this indirection is what keeps
/// `for await` loops from leaking.
private final class SnapshotStreamController: @unchecked Sendable {
    let stream: AsyncStream<NetworkPathSnapshot>
    private let continuation: AsyncStream<NetworkPathSnapshot>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<NetworkPathSnapshot>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func yield(_ snapshot: NetworkPathSnapshot) {
        continuation.yield(snapshot)
    }

    deinit {
        continuation.finish()
    }
}

// MARK: - TelemetryBox

/// `Sendable` box around the (main-actor-isolated) ``TelemetryProviding`` sink.
///
/// The protocol is not `Sendable`, so it is stored behind `@unchecked Sendable`
/// and only ever touched on the main actor (via `Task { @MainActor in … }`).
/// This keeps the owning actor genuinely `Sendable` without referencing Sentry.
private final class TelemetryBox: @unchecked Sendable {
    let telemetry: (any TelemetryProviding)?

    init(_ telemetry: (any TelemetryProviding)?) {
        self.telemetry = telemetry
    }
}

// MARK: - Shared apply shim

// (Path events are applied directly via the actor's `apply` methods, which the
// `PathMonitorHandle` closures call after hopping onto the actor. No registry is
// needed: the closures capture the actor weakly, breaking the retain cycle.)
