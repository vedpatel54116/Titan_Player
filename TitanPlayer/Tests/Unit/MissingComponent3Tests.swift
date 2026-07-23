import XCTest
@testable import TitanPlayer

@MainActor
final class MissingComponent3Tests: XCTestCase {

    // MARK: - Resource tracking

    func testRegisterIncrementsCount() {
        let governor = MissingComponent3(configuration: .init(autoMonitor: false))
        governor.register(.init(label: "t", estimatedBytes: 10, release: {}))
        governor.register(.init(label: "u", estimatedBytes: 10, release: {}))
        XCTAssertEqual(governor.liveResourceCountPublisher.value, 2)
    }

    func testUnregisterReleasesAndDecrements() {
        var released = false
        let resource = MissingComponent3.StreamResource(
            label: "t", estimatedBytes: 10, release: { released = true }
        )
        let governor = MissingComponent3(configuration: .init(autoMonitor: false))
        governor.register(resource)
        let removed = governor.unregister(id: resource.id)
        XCTAssertTrue(removed)
        XCTAssertTrue(released)
        XCTAssertEqual(governor.liveResourceCountPublisher.value, 0)
    }

    // MARK: - Pressure response

    func testReclaimUnderCriticalSnapshotReleasesAll() {
        var released: [String] = []
        let governor = MissingComponent3(configuration: .init(autoMonitor: false))
        governor.register(.init(label: "a", estimatedBytes: 1, release: { released.append("a") }))
        governor.register(.init(label: "b", estimatedBytes: 1, release: { released.append("b") }))

        let critical = SystemStateSnapshot(thermal: .critical, memory: .normal, observedAt: Date())
        let count = try? await governor.reclaimResources(under: critical)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(released.sorted(), ["a", "b"])
        XCTAssertEqual(governor.liveResourceCountPublisher.value, 0)
    }

    func testHandleSnapshotNominalDoesNotReclaim() {
        let governor = MissingComponent3(configuration: .init(autoMonitor: false))
        governor.register(.init(label: "a", estimatedBytes: 1, release: {}))
        let nominal = SystemStateSnapshot(thermal: .nominal, memory: .normal, observedAt: Date())
        governor.handleSnapshot(nominal)
        XCTAssertEqual(governor.liveResourceCountPublisher.value, 1)
    }

    func testReclaimEmitsTelemetry() {
        let telemetry = MockTelemetry()
        let governor = MissingComponent3(telemetry: telemetry, configuration: .init(autoMonitor: false))
        governor.register(.init(label: "a", estimatedBytes: 1, release: {}))
        let critical = SystemStateSnapshot(thermal: .critical, memory: .normal, observedAt: Date())
        _ = try? await governor.reclaimResources(under: critical)
        XCTAssertTrue(telemetry.recorded.contains {
            if case .frameCacheEvicted = $0 { return true } else { return false }
        })
    }

    // MARK: - Guarded acquire

    func testGuardedAcquireReturnsValue() async throws {
        let governor = MissingComponent3(configuration: .init(autoMonitor: false))
        let value = try await governor.withGuardedAcquire(timeout: .seconds(1)) {
            "ok"
        }
        XCTAssertEqual(value, "ok")
    }

    func testGuardedAcquireTimesOut() async {
        let governor = MissingComponent3(configuration: .init(
            acquireTimeout: .milliseconds(50), autoMonitor: false
        ))
        do {
            _ = try await governor.withGuardedAcquire {
                try? await Task.sleep(for: .seconds(2))
                return "never"
            }
            XCTFail("Expected a timeout error")
        } catch let error as MediaError {
            XCTAssertEqual(error.kind, .timedOut)
        } catch {
            XCTFail("Expected MediaError, got \(error)")
        }
    }

    func testGuardedAcquireCancellationMapsToMediaError() async {
        let governor = MissingComponent3(configuration: .init(autoMonitor: false))
        let task = Task {
            try await governor.withGuardedAcquire(timeout: .seconds(5)) {
                try Task.checkCancellation()
                return "never"
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected a cancellation error")
        } catch let error as MediaError {
            XCTAssertEqual(error.kind, .cancelled)
        } catch {
            XCTFail("Expected MediaError, got \(error)")
        }
    }

    // MARK: - Lifecycle

    func testStartStopIsIdempotentAndSafe() {
        let governor = MissingComponent3(configuration: .init(autoMonitor: true))
        governor.start()
        governor.start()
        governor.stop()
        governor.stop()
    }
}
