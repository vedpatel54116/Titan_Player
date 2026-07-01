import Foundation
#if canImport(Darwin)
import Darwin
#endif

@MainActor
final class EnginePerformanceProbe {
    private var cpuProvider: () -> Double = { 0.0 }
    private var memoryProvider: () -> Int64 = { 0 }

    var cpuUsage: Double { cpuProvider() }
    var memoryUsage: Int64 { memoryProvider() }

    init(monitor: PerformanceMonitorProtocol? = nil) {
        if let monitor = monitor {
            cpuProvider = { monitor.currentSystemState.cpuUsage }
        }
        memoryProvider = EnginePerformanceProbe.defaultMemoryProvider
    }

    func _testInject(cpu: Double? = nil, bytes: Int64? = nil) {
        if let cpu = cpu {
            cpuProvider = { cpu }
        }
        if let bytes = bytes {
            memoryProvider = { bytes }
        }
    }

    static let defaultMemoryProvider: () -> Int64 = {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
        #else
        return 0
        #endif
    }
}
