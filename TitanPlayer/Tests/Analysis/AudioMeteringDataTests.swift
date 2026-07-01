import XCTest
@testable import TitanPlayer

final class AudioMeteringDataTests: XCTestCase {
    func testDefaultIntegratedIsNil() {
        let m = AudioMeteringData(
            momentaryLUFS: -23.0,
            shortTermLUFS: -23.0,
            integratedLUFS: nil,
            truePeakDBTP: -1.0,
            peakHoldDBTP: PeakHoldSample(value: -1.0, holdUntil: Date()))
        XCTAssertNil(m.integratedLUFS)
    }

    func testEquatable() {
        let a = AudioMeteringData(
            momentaryLUFS: -23.0,
            shortTermLUFS: -23.0,
            integratedLUFS: -23.5,
            truePeakDBTP: -1.0,
            peakHoldDBTP: PeakHoldSample(value: -1.0, holdUntil: Date()))
        let b = AudioMeteringData(
            momentaryLUFS: -23.0,
            shortTermLUFS: -23.0,
            integratedLUFS: -23.5,
            truePeakDBTP: -1.0,
            peakHoldDBTP: PeakHoldSample(value: -1.0, holdUntil: Date()))
        XCTAssertEqual(a, b)
    }
}
