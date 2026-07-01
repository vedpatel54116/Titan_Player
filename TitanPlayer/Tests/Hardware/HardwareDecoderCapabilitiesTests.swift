import XCTest
@testable import TitanPlayer

final class HardwareDecoderCapabilitiesTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MacModelIdentifier._testInject(nil)
    }

    func test_intelBaseline_hasNoHWHEVC() {
        MacModelIdentifier._testInject(.intelUnknown)
        let caps = HardwareCodecProfile.detect()
        XCTAssertTrue(caps.hasHWH264)
        XCTAssertFalse(caps.hasHWHEVC)
        XCTAssertFalse(caps.hasHDR10)
    }

    func test_M1_supportsHEVCAndHDR10() {
        MacModelIdentifier._testInject(.macMiniM1)
        let caps = HardwareCodecProfile.detect()
        XCTAssertTrue(caps.hasHWH264)
        XCTAssertTrue(caps.hasHWHEVC)
        XCTAssertTrue(caps.hasHDR10)
        XCTAssertTrue(caps.hasHLG)
        XCTAssertFalse(caps.hasProResRAW)
    }

    func test_M2Max_supportsProResRAW() {
        MacModelIdentifier._testInject(.macBookProM2Max)
        let caps = HardwareCodecProfile.detect()
        XCTAssertTrue(caps.hasProResRAW)
        XCTAssertFalse(caps.hasAV1)
    }

    func test_M3Pro_supportsAV1AndDolbyVisionP5() {
        MacModelIdentifier._testInject(.macBookProM3Pro)
        let caps = HardwareCodecProfile.detect()
        XCTAssertTrue(caps.hasAV1)
        XCTAssertTrue(caps.hasDolbyVisionP5)
        XCTAssertFalse(caps.hasDolbyVisionP8)
    }

    func test_M4Pro_supportsDolbyVisionP8() {
        MacModelIdentifier._testInject(.macBookProM4Pro)
        let caps = HardwareCodecProfile.detect()
        XCTAssertTrue(caps.hasDolbyVisionP8)
    }
}
