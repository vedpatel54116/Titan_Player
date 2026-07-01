import XCTest
import Network
@testable import TitanPlayer

@MainActor
final class NetworkMonitorTests: XCTestCase {
    private var monitor: NetworkMonitor!

    override func setUp() {
        super.setUp()
        monitor = NetworkMonitor(skipNWPathStart: true)
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        super.tearDown()
    }

    func testInitialStateIsOfflineNominal() {
        XCTAssertEqual(monitor.reach, .offline)
        XCTAssertEqual(monitor.thermalState, .nominal)
        XCTAssertFalse(monitor.isConstrained)
        XCTAssertFalse(monitor.isExpensive)
    }

    func testSatisfiedWifiUpdatesReach() {
        monitor._testReceivePathUpdate(
            satisfied: true,
            isWiFi: true,
            isCellular: false,
            isWired: false,
            isConstrained: false,
            isExpensive: false
        )
        XCTAssertEqual(monitor.reach, .wifi)
    }

    func testSatisfiedCellularUpdatesReach() {
        monitor._testReceivePathUpdate(
            satisfied: true,
            isWiFi: false,
            isCellular: true,
            isWired: false,
            isConstrained: false,
            isExpensive: true
        )
        XCTAssertEqual(monitor.reach, .cellular)
        XCTAssertTrue(monitor.isExpensive)
    }

    func testSatisfiedWiredUpdatesReach() {
        monitor._testReceivePathUpdate(
            satisfied: true,
            isWiFi: false,
            isCellular: false,
            isWired: true,
            isConstrained: false,
            isExpensive: false
        )
        XCTAssertEqual(monitor.reach, .wired)
    }

    func testUnsatisfiedSetsOffline() {
        monitor._testReceivePathUpdate(
            satisfied: false,
            isWiFi: false,
            isCellular: false,
            isWired: false,
            isConstrained: false,
            isExpensive: false
        )
        XCTAssertEqual(monitor.reach, .offline)
    }

    func testThermalUpdatePropagates() {
        monitor._testReceiveThermal(.critical)
        XCTAssertEqual(monitor.thermalState, .critical)
    }
}
