import Foundation
import Metal
import simd
import Combine
import OSLog

// MARK: - VideoAnalysisConfiguration

/// Tunable limits for the cancellable GPU analysis engine. Every field is a
/// value type, so the configuration is trivially `Sendable` and safe to share.
struct VideoAnalysisConfiguration: Sendable {
    /// Maximum analysis dispatches started per `pushFrame` (bounds concurrency).
    var maxConcurrentDispatches: Int = 3
    /// Upper bound on analysis frames per second (throttles GPU cost).
    var frameRateCap: Double = 30
    /// Deadline applied to every individual Metal compute dispatch.
    var dispatchTimeout: Duration = .seconds(2)
    /// Suspend all analysis under critical thermal state.
    var suspendOnCriticalThermal: Bool = true
    /// Suspend analysis under critical memory-pressure level.
    var evictOnMemoryPressure: Bool = true

    static let `default` = VideoAnalysisConfiguration()
}

// MARK: - VideoAnalysisEngineEvent

/// `Sendable` result/lifecycle events the engine streams back to the main-actor
/// facade for publishing and telemetry.
enum VideoAnalysisEngineEvent: Sendable {
    case histogram(HistogramData)
    case vectorscope(VectorscopeData)
    case waveform(WaveformData)
    case colorSample(ColorSample)
    case error(MediaError)
    case thermalSuspended(ProcessInfo.ThermalState)
    case memoryPressureHandled(Double)
}

// MARK: - SendableTexture

/// `@unchecked Sendable` owner for a non-`Sendable` `MTLTexture`.
///
/// A `MTLTexture` cannot cross an actor boundary, so frames are wrapped here
/// (a `+1` retain via `Unmanaged`) before being handed to ``VideoAnalysisEngine``.
/// The engine releases the wrapper once Metal has captured the texture into a
/// committed command buffer, preventing use-after-free without blocking the
/// render pipeline.
struct SendableTexture: @unchecked Sendable {
    private let reference: Unmanaged<MTLTexture>
    let width: Int
    let height: Int

    init(_ texture: MTLTexture) {
        self.reference = .passRetained(texture)
        self.width = texture.width
        self.height = texture.height
    }

    var texture: MTLTexture { reference.takeUnretainedValue() }

    func release() { reference.release() }
}

// MARK: - VideoAnalysisEngine

/// Genuinely `Sendable` (`final actor`) GPU analysis engine.
///
/// Owns the ``AnalysisGPURunner`` and performs every Metal compute dispatch.
/// It solves the brief's defect — *GPU dispatch lacks cancellation; Metal
/// timeout on seek* — through three mechanisms:
///
/// - **Generation token** (`generation`): bumped by ``cancelInFlight()`` (call
///   on seek). Every in-flight dispatch captures the generation it was started
///   with; when its `MTLCommandBuffer` completes, a stale generation causes the
///   result to be discarded rather than published. This bounds the *visible*
///   effect of a slow pre-seek kernel even though a committed Metal command
///   buffer cannot be hard-cancelled.
/// - **Per-dispatch timeout**: ``runTimed(label:texture:generation:produce:)``
///   races the completion against `configuration.dispatchTimeout`. On timeout the
///   stale result is dropped (the command buffer is *not* cancelled — Metal
///   owns it) and a ``MediaError/Kind/rendererFailure`` is surfaced.
/// - **Pressure suspension**: ``handleThermalState(_:)`` and
///   ``handleMemoryPressure(level:)`` flip `suspended`, which makes
///   ``pushFrame(_:)`` a no-op until conditions recover.
///
/// All errors funnel through ``MediaError``; notable events are streamed via an
/// `AsyncStream` that the facade consumes on the main actor and reports through
/// the `TelemetryProviding` protocol (never Sentry directly).
final actor VideoAnalysisEngine {

    // MARK: Configuration & State

    private let configuration: VideoAnalysisConfiguration
    private let runner: AnalysisGPURunner?
    private let logger = Logger(subsystem: "com.titanplayer", category: "VideoAnalysisEngine")

    private var enabledModes: AnalysisFlags = []
    private var generation: UInt64 = 0
    private var suspended: Bool = false
    private var inFlight: Int = 0
    private var lastDispatchAt: Date = .distantPast

    private let eventStream: AsyncStream<VideoAnalysisEngineEvent>
    private let eventContinuation: AsyncStream<VideoAnalysisEngineEvent>.Continuation

    // MARK: Initialization

    /// Creates the engine with its own `MTLDevice`/`AnalysisGPURunner` (separate
    /// from `MetalRenderer`, matching the original design). If Metal is
    /// unavailable the engine is inert: `pushFrame` becomes a no-op.
    init(configuration: VideoAnalysisConfiguration = .default) {
        self.configuration = configuration
        if let device = MTLCreateSystemDefaultDevice() {
            self.runner = AnalysisGPURunner(device: device)
        } else {
            self.runner = nil
        }
        let (stream, continuation) = AsyncStream<VideoAnalysisEngineEvent>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    /// The stream the facade iterates on the main actor to receive events.
    var events: AsyncStream<VideoAnalysisEngineEvent> { eventStream }

    // MARK: Mode & Lifecycle Control

    /// Update which analysis kernels should run.
    func setModes(_ flags: AnalysisFlags) { enabledModes = flags }

    /// Invalidate every in-flight dispatch by advancing the generation token.
    ///
    /// Call this on seek/stop: results from pre-seek frames are dropped when
    /// their command buffers eventually complete, eliminating stale publishes
    /// and the perceived "Metal timeout on seek".
    func cancelInFlight() { generation &+= 1 }

    /// Pause all analysis until ``resume()`` is called.
    func suspend() { suspended = true }

    /// Resume analysis after a pressure-driven suspension.
    func resume() { suspended = false }

    // MARK: Frame Dispatch

    /// Push a new frame for analysis. No-ops when suspended, with no enabled
    /// modes, when over the concurrency cap, or when throttled by `frameRateCap`.
    func pushFrame(_ sendable: SendableTexture) {
        guard !suspended, runner != nil else { sendable.release(); return }
        guard !enabledModes.isEmpty else { sendable.release(); return }
        let minInterval = 1.0 / max(1.0, configuration.frameRateCap)
        let now = Date()
        guard now.timeIntervalSince(lastDispatchAt) >= minInterval else { sendable.release(); return }
        lastDispatchAt = now

        let gen = generation
        let texture = sendable.texture
        if enabledModes.contains(.histogram)   { tryDispatch { await self.runHistogram(sendable: SendableTexture(texture), generation: gen) } }
        if enabledModes.contains(.vectorscope) { tryDispatch { await self.runVectorscope(sendable: SendableTexture(texture), generation: gen) } }
        if enabledModes.contains(.waveform)    { tryDispatch { await self.runWaveform(sendable: SendableTexture(texture), generation: gen) } }
        sendable.release()
    }

    private func tryDispatch(_ work: @escaping () async -> Void) {
        guard inFlight < configuration.maxConcurrentDispatches else { return }
        inFlight += 1
        Task { [weak self] in
            await work()
            await self?.decrementInFlight()
        }
    }

    private func decrementInFlight() { inFlight -= 1 }

    // MARK: Per-mode dispatch

    private func runHistogram(sendable: SendableTexture, generation gen: UInt64) async {
        guard let runner else { sendable.release(); return }
        let out: HistogramData? = await runTimed(label: "histogram", texture: sendable.texture, generation: gen) { tex, cb in
            runner.runHistogramAsync(texture: tex, completion: cb)
        }
        sendable.release()
        if let out, gen == generation { eventContinuation.yield(.histogram(out)) }
    }

    private func runVectorscope(sendable: SendableTexture, generation gen: UInt64) async {
        guard let runner else { sendable.release(); return }
        let out: VectorscopeData? = await runTimed(label: "vectorscope", texture: sendable.texture, generation: gen) { tex, cb in
            runner.runVectorscopeAsync(texture: tex, completion: cb)
        }
        sendable.release()
        if let out, gen == generation { eventContinuation.yield(.vectorscope(out)) }
    }

    private func runWaveform(sendable: SendableTexture, generation gen: UInt64) async {
        guard let runner else { sendable.release(); return }
        let out: WaveformData? = await runTimed(label: "waveform", texture: sendable.texture, generation: gen) { tex, cb in
            runner.runWaveformAsync(texture: tex, completion: cb)
        }
        sendable.release()
        if let out, gen == generation { eventContinuation.yield(.waveform(out)) }
    }

    /// Synchronous, single-pixel sample. Throws ``MediaError`` on cancel/timeout.
    func sampleColor(texture sendable: SendableTexture, col: Int, row: Int) async throws -> ColorSample {
        defer { sendable.release() }
        guard let runner else {
            throw MediaError(kind: .rendererFailure, source: .local, message: "Analysis runner unavailable")
        }
        let gen = generation
        let simd: SIMD4<Float>? = await runTimed(label: "colorPicker", texture: sendable.texture, generation: gen) { tex, cb in
            runner.samplePixelAsync(texture: tex, col: col, row: row) { cb($0) }
        }
        guard let simd else {
            throw MediaError(kind: .rendererFailure, source: .local, message: "Color sample unavailable or timed out")
        }
        return ColorSample(r: simd.x, g: simd.y, b: simd.z, a: simd.w)
    }

    // MARK: Cancellable, time-bounded dispatch primitive

    /// Run a completion-based Metal kernel (`produce`) and return its result,
    /// resolving exactly once.
    ///
    /// A single `OSAllocatedUnfairLock` guards the continuation so that either
    /// the kernel completion *or* the timeout resolves it — never both — which
    /// avoids the Swift "continuation misused" trap. On timeout the command
    /// buffer is **not** cancelled (Metal owns it); the late completion simply
    /// observes the already-resolved lock and discards its result. A stale
    /// generation (post-seek) likewise yields `nil` so no result is published.
    private func runTimed<T: Sendable>(
        label: String,
        texture: MTLTexture,
        generation gen: UInt64,
        produce: (MTLTexture, @escaping (T?) -> Void) -> Void
    ) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let lock = OSAllocatedUnfairLock(initialState: false)
            let timeout = configuration.dispatchTimeout
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                let should = lock.withLock { state -> Bool in
                    if !state { state = true; return true } else { return false }
                }
                if should {
                    cont.resume(returning: nil)
                    await self?.recordTimeout(label: label)
                }
            }
            produce(texture) { [weak self] out in
                Task { [weak self] in
                    guard let me = self else {
                        let should = lock.withLock { state -> Bool in
                            if !state { state = true; return true } else { return false }
                        }
                        if should { timeoutTask.cancel(); cont.resume(returning: out) }
                        return
                    }
                    let current = await me.generation
                    let valid = gen == current
                    let should = lock.withLock { state -> Bool in
                        if !state { state = true; return true } else { return false }
                    }
                    if should {
                        timeoutTask.cancel()
                        cont.resume(returning: valid ? out : nil)
                    }
                }
            }
        }
    }

    private func recordTimeout(label: String) {
        eventContinuation.yield(.error(MediaError(
            kind: .rendererFailure,
            source: .local,
            message: "Analysis \(label) dispatch exceeded timeout (\(configuration.dispatchTimeout))"
        )))
    }

    // MARK: System-pressure handling

    /// Suspend analysis under critical thermal state; resume otherwise.
    func handleThermalState(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .critical:
            if configuration.suspendOnCriticalThermal {
                suspended = true
                eventContinuation.yield(.thermalSuspended(state))
                logger.warning("VideoAnalysisEngine suspended: thermal \(String(describing: state))")
            }
        default:
            suspended = false
        }
    }

    /// Suspend under critical memory pressure; auto-resume below warning level.
    func handleMemoryPressure(level: Double) {
        if configuration.evictOnMemoryPressure {
            if level >= 0.9 {
                suspended = true
                eventContinuation.yield(.memoryPressureHandled(level))
                logger.warning("VideoAnalysisEngine suspended: memory pressure \(level, format: .fixed(precision: 2))")
            } else if level < 0.5 {
                suspended = false
            }
        }
    }
}

// MARK: - VideoAnalysisManager (SwiftUI facade)

/// `@MainActor` ObservableObject facade for the video-analysis toolset.
///
/// Preserves the exact public surface the app and its tests rely on (toggle
/// flags, published outputs, `attach(frameStore:)`, `sampleColor(at:row:)`,
/// `audioMeter`, `runner`) while delegating all GPU dispatch to the `Sendable`
/// ``VideoAnalysisEngine``. See the type's DocC overview for the rationale.
@MainActor
final class VideoAnalysisManager: ObservableObject {

    // MARK: Published toggles

    @Published var waveformEnabled: Bool = false { didSet { syncModes() } }
    @Published var vectorscopeEnabled: Bool = false { didSet { syncModes() } }
    @Published var histogramEnabled: Bool = false { didSet { syncModes() } }
    @Published var audioMeteringEnabled: Bool = false { didSet { syncModes() } }

    // MARK: Published outputs

    @Published private(set) var histogram: HistogramData?
    @Published private(set) var waveform: WaveformData?
    @Published private(set) var vectorscope: VectorscopeData?
    @Published private(set) var colorPicker: ColorSample?

    // MARK: Subsystems

    /// Retained for API compatibility; the engine owns its own runner/device.
    let runner: AnalysisGPURunner
    let audioMeter: LFSAudioMeter
    private let engine: VideoAnalysisEngine
    private let telemetry: any TelemetryProviding

    private weak var frameStore: FrameStore?
    private var frameIDSink: AnyCancellable?
    private let gpuQueue = DispatchQueue(label: "com.titanplayer.analysis.gpu", qos: .userInitiated)
    private var lastDispatchAt: Date = .distantPast

    private var thermalToken: NSObjectProtocol?
    private var memorySource: DispatchSourceMemoryPressure?

    private let logger = Logger(subsystem: "com.titanplayer", category: "VideoAnalysisManager")

    // MARK: Initialization

    /// - Parameter metalDevice: Device used to build the compatibility `runner`.
    /// - Parameter telemetry: Telemetry sink (defaults to `TelemetryManager.shared`,
    ///   which conforms to `TelemetryProviding` — Sentry is never referenced here).
    init(metalDevice: MTLDevice, telemetry: any TelemetryProviding) {
        self.runner = AnalysisGPURunner(device: metalDevice)
        self.audioMeter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        self.telemetry = telemetry
        self.engine = VideoAnalysisEngine()
        Task { [weak self] in await self?.consumeEvents() }
        setupSystemMonitors()
    }

    /// Convenience initializer using the shared `TelemetryManager` (evaluated on
    /// the main actor, where it is isolated).
    convenience init(metalDevice: MTLDevice) {
        self.init(metalDevice: metalDevice, telemetry: TelemetryManager.shared)
    }

    // MARK: FrameStore attachment

    /// Subscribe to frame updates from the store. No GPU work happens until at
    /// least one analysis mode is enabled.
    func attach(frameStore: FrameStore) {
        self.frameStore = frameStore
        subscribe()
    }

    private func subscribe() {
        guard frameIDSink == nil, let frameStore else { return }
        frameIDSink = frameStore.frameIDPublisher
            .receive(on: gpuQueue)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handleFrameTick() }
            }
    }

    private func unsubscribe() {
        frameIDSink?.cancel()
        frameIDSink = nil
    }

    private func resubscribeIfNeeded() {
        if anyModeEnabled {
            if frameIDSink == nil { subscribe() }
        } else {
            unsubscribe()
        }
    }

    private var anyModeEnabled: Bool {
        histogramEnabled || vectorscopeEnabled || waveformEnabled || audioMeteringEnabled
    }

    private func syncModes() {
        var flags: AnalysisFlags = []
        if histogramEnabled   { flags.insert(.histogram) }
        if vectorscopeEnabled { flags.insert(.vectorscope) }
        if waveformEnabled    { flags.insert(.waveform) }
        Task { await engine.setModes(flags) }
        resubscribeIfNeeded()
    }

    // MARK: Frame tick

    private func handleFrameTick() {
        let now = Date()
        if now.timeIntervalSince(lastDispatchAt) < (1.0 / 30.0) { return }
        lastDispatchAt = now
        guard let texture = frameStore?.latestTexture else { return }
        let sendable = SendableTexture(texture)
        Task { await engine.pushFrame(sendable) }
    }

    /// Source-pixel dimensions of the latest frame (nil before any frame arrives).
    var latestTextureSize: CGSize? {
        guard let t = frameStore?.latestTexture else { return nil }
        return CGSize(width: t.width, height: t.height)
    }

    // MARK: Color sampling

    /// Sample a single pixel from the latest frame. Returns `nil` if no texture
    /// is available; maps any engine failure onto ``MediaError`` + telemetry.
    func sampleColor(at col: Int, row: Int) async -> ColorSample? {
        guard let texture = frameStore?.latestTexture else { return nil }
        let sendable = SendableTexture(texture)
        do {
            return try await engine.sampleColor(texture: sendable, col: col, row: row)
        } catch {
            MediaError(error, source: .local).record(using: telemetry)
            return nil
        }
    }

    // MARK: Seek / pressure integration (call from PlaybackSession)

    /// Invalidate in-flight analysis dispatches (call on seek to prevent stale
    /// post-seek publishes — the core fix for the Metal-timeout-on-seek defect).
    func cancelPendingDispatches() {
        Task { await engine.cancelInFlight() }
    }

    /// Forward a thermal-state change to the engine.
    func handleThermalState(_ state: ProcessInfo.ThermalState) {
        Task { await engine.handleThermalState(state) }
    }

    /// Forward a memory-pressure level (0.5 warning, 1.0 critical) to the engine.
    func handleMemoryPressure(level: Double) {
        Task { await engine.handleMemoryPressure(level: level) }
    }

    // MARK: Telemetry & event consumption

    private func consumeEvents() async {
        for await event in await engine.events {
            deliver(event)
        }
    }

    private func deliver(_ event: VideoAnalysisEngineEvent) {
        switch event {
        case .histogram(let h):        histogram = h
        case .vectorscope(let v):      vectorscope = v
        case .waveform(let w):         waveform = w
        case .colorSample(let c):      colorPicker = c
        case .error(let e):            e.record(using: telemetry)
        case .thermalSuspended(let s): MediaError.thermalPressure(state: s, source: .local).record(using: telemetry)
        case .memoryPressureHandled(_): MediaError.memoryPressure(source: .local).record(using: telemetry)
        }
    }

    // MARK: System monitoring

    private func setupSystemMonitors() {
        thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            Task { @MainActor in self?.handleThermalState(state) }
        }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: gpuQueue
        )
        source.setEventHandler { [weak self] in
            let level: Double = source.mask.contains(.critical) ? 1.0 : 0.5
            Task { @MainActor in self?.handleMemoryPressure(level: level) }
        }
        source.resume()
        memorySource = source
    }

    // MARK: Teardown

    deinit {
        frameIDSink?.cancel()
        if let token = thermalToken { NotificationCenter.default.removeObserver(token) }
        memorySource?.cancel()
    }
}
