import XCTest
@testable import TitanPlayer

final class AudioFormatDetectorTests: XCTestCase {
    func testDetectsPCMFormat() throws {
        let detector = AudioFormatDetector()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        
        let detected = detector.detectFormat(from: format)
        
        XCTAssertEqual(detected, .pcm)
    }
    
    func testDetectsAACFormat() throws {
        let detector = AudioFormatDetector()
        let format = AVAudioFormat(commonFormat: .aac, sampleRate: 48000, channels: 2, interleaved: false)
        
        let detected = detector.detectFormat(from: format)
        
        XCTAssertEqual(detected, .aac)
    }
}