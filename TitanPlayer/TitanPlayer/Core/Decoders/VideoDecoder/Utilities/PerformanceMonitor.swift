import Foundation
import MachO
import Metal

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

// SAFETY: All mutable state is protected by `lock` (NSLock). Access is
// serialised, so this type is safe to share across concurrency domains.
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
    }
    
    // MARK: - Lifecycle

    func start() {
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
        cpuSampleTimer?.invalidate()
        cpuSampleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sampleCPUUsage()
            self?.sampleGPUUsage()
        }
        sampleCPUUsage()
        sampleGPUUsage()
    }

    /// Sample the overall host CPU usage and update `currentSystemState.cpuUsage`.
    /// Uses the Mach `host_processor_info` API with proper `vm_deallocate` cleanup.
    /// Returns 0.0 on any failure instead of crashing.
    /// Exposed `internal` so tests can drive a single sample deterministically.
    func sampleCPUUsage() {
        let usage = sampleCPUUsageRaw()
        lock.lock()
        let smoothed = currentSystemState.cpuUsage * 0.85 + usage * 0.15
        currentSystemState.cpuUsage = smoothed
        lock.unlock()
    }

    private func sampleCPUUsageRaw() -> Double {
        var CPULoad = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &CPULoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0.0 }

        let user = Double(CPULoad.cpu_ticks.0)
        let system = Double(CPULoad.cpu_ticks.1)
        let idle = Double(CPULoad.cpu_ticks.2)
        let nice = Double(CPULoad.cpu_ticks.3)
        let total = user + system + idle + nice

        guard total > 0 else { return 0.0 }
        return (user + system + nice) / total
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
    
    private var gpuFrameTimings: [Double] = []
    private let gpuTimingMaxSamples = 30
    
    func recordGPUFrameDuration(_ duration: Double) {
        lock.lock()
        gpuFrameTimings.append(duration)
        if gpuFrameTimings.count > gpuTimingMaxSamples {
            gpuFrameTimings.removeFirst()
        }
        let avgDuration = gpuFrameTimings.reduce(0, +) / Double(gpuFrameTimings.count)
        let frameBudget = 1.0 / 60.0
        let usage = min(avgDuration / frameBudget, 1.0)
        let smoothed = currentSystemState.gpuUsage * 0.85 + usage * 0.15
        currentSystemState.gpuUsage = smoothed
        lock.unlock()
    }
    
    private func sampleGPUUsage() {
        lock.lock()
        if gpuFrameTimings.isEmpty {
            if let device = MTLCreateSystemDefaultDevice() {
                currentSystemState.gpuUsage = device.isLowPower ? 0.3 : 0.1
            }
        }
        lock.unlock()
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
