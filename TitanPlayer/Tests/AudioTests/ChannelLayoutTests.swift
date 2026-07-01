import XCTest
import AVFAudio
@testable import TitanPlayer

final class ChannelLayoutTests: XCTestCase {
    func testStereoLayoutCreation() {
        let layout = ChannelLayout.stereo

        XCTAssertEqual(layout.channelCount, 2)
        XCTAssertEqual(layout.channelDescriptions[0].mChannelLabel, kAudioChannelLabel_Left)
        XCTAssertEqual(layout.channelDescriptions[1].mChannelLabel, kAudioChannelLabel_Right)
    }

    func testSurroundLayoutCreation() {
        let layout = ChannelLayout.surround5_1

        XCTAssertEqual(layout.channelCount, 6)
    }
}
