import Foundation
import AVFoundation
@testable import TitanPlayer

@MainActor
final class MockNetworkMonitor: NetworkMonitorProtocol, ObservableObject {
    @Published var reach: Reach = .offline
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    
    func inject(_ state: ProcessInfo.ThermalState) {
        thermalState = state
    }
}
