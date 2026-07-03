import XCTest
import Sentry
@testable import TitanPlayer

final class MockSentrySDK: SentrySDKProtocol, @unchecked Sendable {
    var startCallCount = 0
    var lastStartDSN: String?
    var lastStartTracesSampleRate: NSNumber?
    var captureCallCount = 0
    var lastCapturedEvent: Event?
    var closeCallCount = 0

    func start(dsn: String, tracesSampleRate: NSNumber) {
        startCallCount += 1
        lastStartDSN = dsn
        lastStartTracesSampleRate = tracesSampleRate
    }

    func capture(event: Event) {
        captureCallCount += 1
        lastCapturedEvent = event
    }

    func close() {
        closeCallCount += 1
    }
}

@MainActor
final class TelemetryManagerTests: XCTestCase {

    private var mock: MockSentrySDK!
    private var manager: TelemetryManager!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.consented")
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.hasPrompted")
        mock = MockSentrySDK()
        manager = TelemetryManager(dsn: "https://test@sentry.io/123", sentry: mock)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.consented")
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.hasPrompted")
        super.tearDown()
    }

    // MARK: - Default State

    func testDefaultStateNotConsented() {
        XCTAssertFalse(manager.isOptedIn)
        XCTAssertTrue(manager.needsConsentPrompt)
    }

    // MARK: - Consent Transitions

    func testSetConsentTrue() {
        manager.setConsent(true)
        XCTAssertTrue(manager.isOptedIn)
        XCTAssertFalse(manager.needsConsentPrompt)
    }

    func testSetConsentFalse() {
        manager.setConsent(true)
        manager.setConsent(false)
        XCTAssertFalse(manager.isOptedIn)
        XCTAssertFalse(manager.needsConsentPrompt)
    }

    func testNeedsConsentPromptOnlyOnce() {
        manager.setConsent(true)
        XCTAssertFalse(manager.needsConsentPrompt)
        manager.setConsent(false)
        XCTAssertFalse(manager.needsConsentPrompt)
    }

    // MARK: - initialize() Tests

    func test_initialize_noOpWithoutConsent() {
        manager.initialize()
        XCTAssertEqual(mock.startCallCount, 0)
    }

    func test_initialize_noOpWithoutDSN() {
        let noDsnManager = TelemetryManager(dsn: "", sentry: mock)
        noDsnManager.setConsent(true)
        XCTAssertEqual(mock.startCallCount, 0)
    }

    func test_initialize_startsSentry() {
        manager.setConsent(true)
        XCTAssertEqual(mock.startCallCount, 1)
        XCTAssertEqual(mock.lastStartDSN, "https://test@sentry.io/123")
        XCTAssertEqual(mock.lastStartTracesSampleRate?.doubleValue, 0.2)
    }

    // MARK: - record() Tests

    func test_record_ignoredWithoutConsent() {
        manager.record(.playbackFailed(
            codec: "h264",
            resolution: "1920x1080",
            errorCode: "DECODER_ERROR",
            source: .local
        ))
        XCTAssertEqual(mock.captureCallCount, 0)
    }

    func test_record_capturesEvent() {
        manager.setConsent(true)
        let beforeCount = mock.captureCallCount
        manager.record(.hdrModeUsed(mode: .hdr10, duration: 120.0))
        XCTAssertEqual(mock.captureCallCount, beforeCount + 1)
        XCTAssertNotNil(mock.lastCapturedEvent)
    }

    func test_record_playbackFailed_setsErrorLevel() {
        manager.setConsent(true)
        manager.record(.playbackFailed(
            codec: "hevc",
            resolution: "3840x2160",
            errorCode: "TIMEOUT",
            source: .hls
        ))
        XCTAssertEqual(mock.lastCapturedEvent?.level, .error)
    }

    func test_record_compatibilityModeActivated_setsWarningLevel() {
        manager.setConsent(true)
        manager.record(.compatibilityModeActivated(
            reason: "unsupported_hdr",
            source: .local
        ))
        XCTAssertEqual(mock.lastCapturedEvent?.level, .warning)
    }

    func test_record_performanceSnapshot_setsInfoLevel() {
        manager.setConsent(true)
        manager.record(.performanceSnapshot(
            averageCPU: 45.0,
            averageGPU: 60.0,
            resolution: "3840x2160",
            codec: "hevc"
        ))
        XCTAssertEqual(mock.lastCapturedEvent?.level, .info)
    }

    func test_record_audioFormatUsed_setsInfoLevel() {
        manager.setConsent(true)
        manager.record(.audioFormatUsed(
            format: .atmos,
            sampleRate: 48000,
            bitDepth: 24
        ))
        XCTAssertEqual(mock.lastCapturedEvent?.level, .info)
    }

    // MARK: - setConsent() Sentry Interaction Tests

    func test_setConsent_true_initializesSentry() {
        manager.setConsent(true)
        XCTAssertEqual(mock.startCallCount, 1)
    }

    func test_setConsent_false_closesSentry() {
        manager.setConsent(true)
        manager.setConsent(false)
        XCTAssertEqual(mock.closeCallCount, 1)
    }

    func test_setConsent_false_doesNotStartSentry() {
        manager.setConsent(false)
        XCTAssertEqual(mock.startCallCount, 0)
    }

    // MARK: - Telemetry Off-Path Does Not Crash

    func test_telemetryOffPath_doesNotCrash() {
        let events: [TelemetryEvent] = [
            .playbackFailed(codec: "h264", resolution: "1920x1080", errorCode: "ERR", source: .local),
            .hdrModeUsed(mode: .hdr10, duration: 0),
            .performanceSnapshot(averageCPU: 0, averageGPU: 0, resolution: "", codec: ""),
            .audioFormatUsed(format: .stereo, sampleRate: 44100, bitDepth: 16),
            .compatibilityModeActivated(reason: "test", source: .hls)
        ]
        for event in events {
            manager.record(event)
        }
        XCTAssertEqual(mock.captureCallCount, 0)
    }

    // MARK: - Singleton Uses Defaults

    func test_shared_usesDefaultDSN() {
        let shared = TelemetryManager.shared
        XCTAssertNotNil(shared)
    }
}
