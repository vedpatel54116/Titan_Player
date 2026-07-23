import XCTest
@testable import TitanPlayer

/// Tests for the actor-based ``NetworkPathMonitor``.
///
/// These exercise the parts that need no live network: the nominal starting
/// snapshot, the ABR capacity-score math, MediaError mapping on timeout, and
/// the `Sendable` conformance. Live `NWPathMonitor` transitions are covered
/// manually (they require a real interface handover).
final class NetworkPathMonitorTests: XCTestCase {

    func testNominalSnapshotIsOffline() async {
        let monitor = NetworkPathMonitor(startImmediately: false)
        let snapshot = await monitor.snapshot()
        XCTAssertEqual(snapshot.reach, .offline)
        XCTAssertFalse(snapshot.isSatisfied)
        XCTAssertEqual(snapshot.estimatedCapacityScore, 0.0, accuracy: 1e-6)
    }

    func testCapacityScoreForWiredIsMaximal() {
        let snapshot = NetworkPathSnapshot(
            reach: .wired,
            interfaces: [.wiredEthernet],
            isExpensive: false,
            isConstrained: false,
            thermal: .nominal,
            memory: .normal,
            observedAt: Date()
        )
        XCTAssertEqual(snapshot.estimatedCapacityScore, 1.0, accuracy: 1e-6)
    }

    func testCapacityScoreDegradesUnderPressure() {
        let snapshot = NetworkPathSnapshot(
            reach: .cellular,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: true,
            thermal: .serious,
            memory: .warning,
            observedAt: Date()
        )
        // Cellular + expensive + constrained + serious thermal + memory warning
        // must land well below the Wi-Fi baseline.
        XCTAssertLessThan(snapshot.estimatedCapacityScore, 0.5)
    }

    func testWaitUntilSatisfiedTimesOutAsMediaError() async {
        let monitor = NetworkPathMonitor(startImmediately: false)
        do {
            _ = try await monitor.waitUntilSatisfied(within: .milliseconds(50))
            XCTFail("Expected a timeout error")
        } catch let error as MediaError {
            XCTAssertEqual(error.kind, .timedOut, "timeouts must map to MediaError(.timedOut)")
        } catch {
            XCTFail("Errors must be mapped to MediaError, got \(error)")
        }
    }

    func testSendableConformance() {
        // Compile-time assertion that the monitor is genuinely `Sendable`.
        let monitor: any Sendable = NetworkPathMonitor(startImmediately: false)
        XCTAssertNotNil(monitor)
    }
}
