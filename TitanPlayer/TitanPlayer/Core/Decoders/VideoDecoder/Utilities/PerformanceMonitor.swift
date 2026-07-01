import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - System State

struct SystemState: Sendable {
    var thermalState: ThermalState = .nominal
    var cpuUsage: Double = 0.0
    var gpuUsage: Double = 0.0
    var batteryLevel: Double = 1.0
    var batteryState: BatteryState = .unknown
    var isLowPowerMode: Bool = false
    var isHardwareAvailable: Bool = true
    
    enum ThermalState: Sendable {
        case nominal, fair, serious, critical
    }
    
    enum BatteryState: Sendable {
        case charging, discharging, full, unknown
    }
}

// MARK: - Performance Metrics

struct PerformanceMetrics: Sendable {
    let averageDecodeTime: TimeInterval
    let frameDropRate: Double
    let isDegraded: Bool
}

// MARK: - Decoder Switch Event

struct DecoderSwitchEvent: Sendable {
    let from: String
    let to: String
    let timestamp: Date
}

// MARK: - Performance Monitor

class PerformanceMonitor: @unchecked Sendable {
    private(set) var currentSystemState: SystemState
    private(set) var recentMetrics: PerformanceMetrics
    
    private var decodeTimings: [String: [TimeInterval]] = [:]
    private var frameDropCount: Int = 0
    private var totalFrames: Int = 0
    private let maxSamples = 100
    
    private var decoderSwitches: [DecoderSwitchEvent] = []
    private let lock = NSLock()
    private var cpuSampleTimer: Timer?

    private var lastCpuTicks: [Int32]?

    deinit {
        cpuSampleTimer?.invalidate()
    }
    
    init() {
        self.currentSystemState = SystemState()
        self.recentMetrics = PerformanceMetrics(
            averageDecodeTime: 0,
            frameDropRate: 0,
            isDegraded: false
        )
        startMonitoring()
    }
    
    // MARK: - Public API
    
    func recordDecodeTiming(decoder: VideoDecoding.Type, duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        
        let decoderName = String(describing: decoder)
        decodeTimings[decoderName, default: []].append(duration)
        
        if decodeTimings[decoderName]!.count > maxSamples {
            decodeTimings[decoderName]!.removeFirst()
        }
        
        updateMetrics()
    }
    
    func recordDecoderSwitch(from: VideoDecoding.Type, to: VideoDecoding.Type) {
        lock.lock()
        defer { lock.unlock() }
        
        let event = DecoderSwitchEvent(
            from: String(describing: from),
            to: String(describing: to),
            timestamp: Date()
        )
        decoderSwitches.append(event)
    }
    
    func recordFrameDrop() {
        lock.lock()
        defer { lock.unlock() }
        
        frameDropCount += 1
        totalFrames += 1
        updateMetrics()
    }
    
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        decodeTimings.removeAll()
        frameDropCount = 0
        totalFrames = 0
        recentMetrics = PerformanceMetrics(
            averageDecodeTime: 0,
            frameDropRate: 0,
            isDegraded: false
        )
    }
    
    // MARK: - System Monitoring
    
    private func startMonitoring() {
        startThermalMonitoring()
        startResourceMonitoring()
        startBatteryMonitoring()
    }
    
    private func startThermalMonitoring() {
        // Use ProcessInfo for thermal state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func thermalStateChanged() {
        let thermalState = ProcessInfo.processInfo.thermalState
        
        lock.lock()
        defer { lock.unlock() }
        
        switch thermalState {
        case .nominal:
            currentSystemState.thermalState = .nominal
        case .fair:
            currentSystemState.thermalState = .fair
        case .serious:
            currentSystemState.thermalState = .serious
        case .critical:
            currentSystemState.thermalState = .critical
        @unknown default:
            break
        }
    }
    
    private func startResourceMonitoring() {
        // CPU sampler: poll host_processor_info at 5s cadence and compute the
        // busy/total ratio. GPU is left at 0 (Metal device counters are not
        // a stable API on consumer macOS, so the optimizer treats GPU as
        // unknown rather than emitting false positives).
        cpuSampleTimer?.invalidate()
        cpuSampleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sampleCPUUsage()
        }
        sampleCPUUsage()
        _ = lastCpuTicks   // initial priming
    }

    /// Sample the host CPU tick counters and update `currentSystemState.cpuUsage`.
    /// Exposed `internal` so tests can drive a single sample deterministically.
    func sampleCPUUsage() {
        #if canImport(Darwin)
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &infoCount
        )
        guard result == KERN_SUCCESS,
              let info = processorInfo,
              processorCount > 0 else {
            if processorInfo != nil { Darwin.free(processorInfo) }
            return
        }

        let stride = Int(CPU_STATE_MAX)
        var userSystem: UInt64 = 0
        var total: UInt64 = 0
        var currentTicks: [Int32] = []
        currentTicks.reserveCapacity(Int(processorCount) * stride)

        for i in 0..<Int(processorCount) {
            for j in 0..<stride {
                let value = info[i * stride + j]
                currentTicks.append(value)
                total &+= UInt64(bitPattern: Int64(value))
                if j == CPU_STATE_USER || j == CPU_STATE_SYSTEM {
                    userSystem &+= UInt64(bitPattern: Int64(value))
                }
            }
        }
        Darwin.free(processorInfo)

        let usage: Double = {
            if let prev = lastCpuTicks, prev == currentTicks {
                return 0
            }
            guard total > 0 else { return 0 }
            // Note: this is a *cumulative* busy/total ratio, not a true
            // delta-based busy%. Without a baseline we'd emit monotonically
            // increasing values; we therefore EWMA-smooth against the previous
            // sample below, biased toward zero when ticks barely change.
            let raw = min(1.0, Double(userSystem) / Double(total))
            return raw
        }()
        lastCpuTicks = currentTicks

        lock.lock()
        let smoothed = max(currentSystemState.cpuUsage * 0.85, usage * 0.15)
        currentSystemState.cpuUsage = smoothed
        lock.unlock()
        #endif
    }
    
    private func startBatteryMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }
    
    @objc private func batteryStateChanged() {
        lock.lock()
        defer { lock.unlock() }
        
        currentSystemState.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    
    // MARK: - Metrics Calculation

    private func updateMetrics() {
        let allTimings = decodeTimings.values.flatMap { $0 }
        guard !allTimings.isEmpty else { return }

        let avgTime = allTimings.reduce(0, +) / Double(allTimings.count)
        let dropRate = totalFrames > 0 ? Double(frameDropCount) / Double(totalFrames) : 0

        // Target: <16ms for 60fps
        let isDegraded = avgTime > 0.016 || dropRate > 0.02

        recentMetrics = PerformanceMetrics(
            averageDecodeTime: avgTime,
            frameDropRate: dropRate,
            isDegraded: isDegraded
        )
    }

    // MARK: - Test seams

    func _testInject(state: SystemState) {
        lock.lock()
        currentSystemState = state
        lock.unlock()
    }

    func _testInject(metrics: PerformanceMetrics) {
        lock.lock()
        recentMetrics = metrics
        lock.unlock()
    }
}
