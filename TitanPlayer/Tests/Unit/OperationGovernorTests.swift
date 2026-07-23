import XCTest
@testable import TitanPlayer

// MARK: - OperationGovernorTests

@MainActor
final class OperationGovernorTests: XCTestCase {

    // MARK: Happy path

    func testRunsOperationAndReturnsValue() async throws {
        let governor = OperationGovernor()
        let value: Int = try await governor.run { 42 }
        XCTAssertEqual(value, 42)
    }

    func testHonorsCustomTimeoutArgument() async throws {
        let governor = OperationGovernor()
        let value: String = try await governor.run(
            { "done" },
            timeout: .seconds(5),
            context: "custom-timeout"
        )
        XCTAssertEqual(value, "done")
    }

    // MARK: Failure mapping

    func testTimeoutMapsToTimedOut() async {
        let governor = OperationGovernor(configuration: .init(defaultTimeout: .milliseconds(50)))
        do {
            _ = try await governor.run {
                try await Task.sleep(for: .seconds(2))
                return "never"
            }
            XCTFail("Expected a timeout error")
        } catch {
            let mediaError = error as? MediaError
            XCTAssertEqual(mediaError?.kind, .timedOut)
        }
    }

    func testExternalCancellationMapsToCancelled() async {
        let governor = OperationGovernor()
        let task = Task {
            try await governor.run {
                try await Task.sleep(for: .seconds(5))
                return "never"
            }
        }
        task.cancel()
        do {
            _ = try await task
            XCTFail("Expected a cancellation error")
        } catch {
            let mediaError = error as? MediaError
            XCTAssertEqual(mediaError?.kind, .cancelled)
        }
    }

    // MARK: Telemetry

    func testFailureRecordsPlaybackFailedEvent() async {
        let mock = MockTelemetry()
        let governor = OperationGovernor(
            configuration: .init(defaultTimeout: .milliseconds(50), telemetry: mock)
        )
        do {
            _ = try await governor.run { try await Task.sleep(for: .seconds(2)); return 1 }
        } catch {
            XCTAssertEqual((error as? MediaError)?.kind, .timedOut)
        }

        let event = try XCTUnwrap(mock.recordedEvents.first)
        guard case .playbackFailed(_, _, let errorCode, _) = event else {
            return XCTFail("Expected a playbackFailed telemetry event")
        }
        XCTAssertEqual(errorCode, "timed_out")
    }

    func testSuccessDoesNotRecordTelemetry() async {
        let mock = MockTelemetry()
        let governor = OperationGovernor(configuration: .init(telemetry: mock))
        _ = try? await governor.run { 1 }
        XCTAssertTrue(mock.recordedEvents.isEmpty)
    }
}

// MARK: - MockTelemetry

@MainActor
final class MockTelemetry: TelemetryProviding {
    var recordedEvents: [TelemetryEvent] = []
    var isOptedIn = true
    var needsConsentPrompt = false

    func initialize() {}
    func record(_ event: TelemetryEvent) { recordedEvents.append(event) }
    func setConsent(_ granted: Bool) {}
}
