import XCTest
import AVFAudio
@testable import TitanPlayer

@MainActor
final class LFSAudioMeterTests: XCTestCase {
    private func makeFormat(channels: UInt32 = 2) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels)!
    }

    func testZeroMeteringAtStart() {
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        XCTAssertEqual(meter.metering.momentaryLUFS, -120.0, accuracy: 0.001)
        XCTAssertNil(meter.metering.integratedLUFS)
    }

    func testSilenceKeepsMomentaryAtMinus120() {
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let format = makeFormat()
        let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        zeros.frameLength = 4800
        for ch in 0..<Int(format.channelCount) {
            memset(zeros.floatChannelData![ch], 0, Int(4800) * MemoryLayout<Float>.size)
        }
        meter.consume(buffer: zeros)
        // After dispatch + publish cycle, momentary stays at –120 LUFS for silence.
        let exp = expectation(description: "publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(meter.metering.momentaryLUFS, -120.0, accuracy: 0.5)
    }

    func testStereoOneKHzZeroDBFSPeakOneProducesApproximatelyMinus0Point691LUFS() {
        // Stereo 1 kHz sine, L=R=peak 1.0:
        //   per-channel RMS ≈ 0.7071, mean-square ≈ 0.5
        //   K-weighting unity at 1 kHz → K-weighted per-channel MS = 0.5 (-3.01 dBFS_K)
        //   BS.1770-4 L+R summed → MS = 1.0 → 0 dBFS_K → –0.691 LUFS
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let format = makeFormat()
        let frames = 4800 * 5    // 0.5 s
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<frames {
                p[i] = Float(sin(2.0 * .pi * 1000.0 * Double(i) / 48000.0))
            }
        }
        meter.consume(buffer: buf)
        let exp = expectation(description: "publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(meter.metering.momentaryLUFS ?? 0, -0.691, accuracy: 1.0)
    }
}