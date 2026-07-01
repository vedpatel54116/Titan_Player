import XCTest
@testable import TitanPlayer

final class MacModelIdentifierTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MacModelIdentifier._testInject(nil)
    }

    func test_detectReturnsNonEmpty() {
        let id = MacModelIdentifier.detect()
        XCTAssertFalse(id.rawValue.isEmpty)
    }

    func test_parseKnownModel() {
        XCTAssertEqual(MacModelIdentifier.parse("MacBookPro18,1"), .macBookProM1Max)
        XCTAssertEqual(MacModelIdentifier.parse("Macmini9,1"), .macMiniM1)
        XCTAssertEqual(MacModelIdentifier.parse("MacBookPro19,2"), .macBookProM2Max)
    }

    func test_parseUnknownModelReturnsNil() {
        XCTAssertNil(MacModelIdentifier.parse(""))
        XCTAssertNil(MacModelIdentifier.parse("DreamDevice99,9"))
    }

    func test_testInjectOverridesDetected() {
        MacModelIdentifier._testInject(.macBookProM1Max)
        XCTAssertEqual(MacModelIdentifier.detect(), .macBookProM1Max)
    }

    func test_isAppleSilicon() {
        XCTAssertFalse(MacModelIdentifier.intelUnknown.isAppleSilicon)
        XCTAssertTrue(MacModelIdentifier.macMiniM1.isAppleSilicon)
        XCTAssertTrue(MacModelIdentifier.macBookProM4Pro.isAppleSilicon)
    }

    func test_shortLabelIsHumanReadable() {
        XCTAssertEqual(MacModelIdentifier.macBookProM1Max.shortLabel, "MBP M1 Max")
        XCTAssertEqual(MacModelIdentifier.intelUnknown.shortLabel, "Intel (unknown)")
    }
}
