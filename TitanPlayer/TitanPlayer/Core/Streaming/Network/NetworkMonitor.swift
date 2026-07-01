import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var reach: Reach = .offline
    @Published private(set) var isConstrained: Bool = false
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    private var pathMonitor: NWPathMonitor?
    private var thermalTimer: Timer?

    init(skipNWPathStart: Bool = false) {
        if !skipNWPathStart {
            start()
        }
    }

    deinit {
        pathMonitor?.cancel()
        thermalTimer?.invalidate()
    }

    func start() {
        pathMonitor?.cancel()
        let pm = NWPathMonitor()
        pm.pathUpdateHandler = { [weak self] path in
            let isWiFi = path.usesInterfaceType(.wifi)
            let isCellular = path.usesInterfaceType(.cellular)
            let isWired = path.usesInterfaceType(.wiredEthernet)
            let satisfied = path.status == .satisfied
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?._testReceivePathUpdate(
                    satisfied: satisfied,
                    isWiFi: isWiFi,
                    isCellular: isCellular,
                    isWired: isWired,
                    isConstrained: constrained,
                    isExpensive: expensive
                )
            }
        }
        pm.start(queue: DispatchQueue(label: "titanplayer.network.monitor"))
        pathMonitor = pm

        thermalTimer?.invalidate()
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            Task { @MainActor [weak self] in
                self?._testReceiveThermal(state)
            }
        }
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        thermalTimer?.invalidate()
        thermalTimer = nil
    }

    // MARK: Test seams

    func _testReceivePathUpdate(
        satisfied: Bool,
        isWiFi: Bool,
        isCellular: Bool,
        isWired: Bool,
        isConstrained: Bool,
        isExpensive: Bool
    ) {
        if !satisfied {
            reach = .offline
        } else if isWiFi {
            reach = .wifi
        } else if isCellular {
            reach = .cellular
        } else if isWired {
            reach = .wired
        } else {
            reach = .wifi   // default satisfied
        }
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }

    func _testReceiveThermal(_ state: ProcessInfo.ThermalState) {
        thermalState = state
    }
}

protocol NetworkMonitorProtocol: AnyObject {
    var reach: Reach { get }
    var thermalState: ProcessInfo.ThermalState { get }
}
extension NetworkMonitor: NetworkMonitorProtocol {}
