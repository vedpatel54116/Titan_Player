import XCTest
@testable import TitanPlayer

final class AudioFormatDetectorTests: XCTestCase {
    func testDetectsPCMFormat() {
        let detector = AudioFormatDetector()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

        let detected = detector.detectFormat(from: format)

        XCTAssertEqual(detected, .pcm)
    }

    func testDetectsUnknownForNonPCMStandardFormat() {
        let detector = AudioFormatDetector()
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: false)!

        let detected = detector.detectFormat(from: format)

        XCTAssertEqual(detected, .pcm)
    }
}
