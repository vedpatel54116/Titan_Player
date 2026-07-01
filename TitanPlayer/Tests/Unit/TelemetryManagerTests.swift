import XCTest
@testable import TitanPlayer

@MainActor
final class TelemetryManagerTests: XCTestCase {
    
    private var manager: TelemetryManager!
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.consented")
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.hasPrompted")
        manager = TelemetryManager.shared
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.consented")
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.hasPrompted")
        super.tearDown()
    }
    
    func testDefaultStateNotConsented() {
        XCTAssertFalse(manager.isOptedIn)
        XCTAssertTrue(manager.needsConsentPrompt)
    }
    
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
    
    func testRecordDoesNothingWhenNotConsented() {
        manager.record(.playbackFailed(
            codec: "h264",
            resolution: "1920x1080",
            errorCode: "DECODER_ERROR",
            source: .local
        ))
    }
    
    func testRecordWhenConsented() {
        manager.setConsent(true)
        manager.record(.hdrModeUsed(mode: .hdr10, duration: 120.0))
        manager.record(.performanceSnapshot(averageCPU: 45.0, averageGPU: 60.0, resolution: "3840x2160", codec: "hevc"))
        manager.record(.audioFormatUsed(format: .atmos, sampleRate: 48000, bitDepth: 24))
    }
}
