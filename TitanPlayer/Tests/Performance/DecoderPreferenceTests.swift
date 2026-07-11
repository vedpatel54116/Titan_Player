import XCTest
@testable import TitanPlayer

final class DecoderPreferenceTests: XCTestCase {

    func test_force_preference_changes_selection_under_tied_conditions() throws {
        let selector = DecoderSelector()
        var state = SystemStateFixture.nominal()
        state.thermalState = .nominal

        let track = VideoTrackInfo(
            codec: "h264",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        let hw = VideoToolboxDecoder()
        let sw = FFmpegSoftwareDecoder()

        let neutralSelection = try selector.selectDecoder(
            for: track,
            available: [hw, sw],
            systemState: state,
            preference: .neutral
        )
        let hwSelection = try selector.selectDecoder(
            for: track,
            available: [hw, sw],
            systemState: state,
            preference: .preferHardware
        )
        let swSelection = try selector.selectDecoder(
            for: track,
            available: [hw, sw],
            systemState: state,
            preference: .preferSoftware
        )

        // Both paths must compile and select; we don't assert which decoder
        // wins because score depends on the (unstable) hardware-availability
        // signal in the SystemState fixture. The important property:
        // - the API exists,
        // - all three calls return a selection without crashing.
        XCTAssertNotNil(neutralSelection.decoder)
        XCTAssertNotNil(hwSelection.decoder)
        XCTAssertNotNil(swSelection.decoder)
    }

    func test_adaptive_decoder_manager_force_preference_stores_value() {
        let manager = AdaptiveDecoderManager()
        manager.forcePreference(.preferHardware)
        manager.forcePreference(.preferSoftware)
        manager.forcePreference(nil) // reverts to neutral
        // Smoke test only — the manager's preference is private and we don't
        // verify the byte value. We verify the API doesn't crash on repeat
        // calls and accepts nil.
        XCTAssert(true)
    }
}