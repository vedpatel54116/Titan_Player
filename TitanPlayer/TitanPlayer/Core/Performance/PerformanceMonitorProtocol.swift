import Foundation

protocol PerformanceMonitorProtocol: AnyObject {
    var currentSystemState: SystemState { get }
    var recentMetrics: PerformanceMetrics { get }
}

extension PerformanceMonitor: PerformanceMonitorProtocol {}
