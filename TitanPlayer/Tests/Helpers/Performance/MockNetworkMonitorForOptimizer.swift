import Foundation
@testable import TitanPlayer

final class MockNetworkMonitor: NetworkMonitorProtocol {
    var reach: Reach = .wifi
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    func inject(_ s: ProcessInfo.ThermalState) { thermalState = s }
}
