import XCTest
import CoreMedia
@testable import TitanPlayer

final class FFmpegAudioDecoderTests: XCTestCase {

    // MARK: Codec recognition

    func testRecognizesSurroundBitstreamCodecs() {
        XCTAssertEqual(FFmpegAudioDecoder.AudioCodec(parsing: "ac3"), .ac3)
        XCTAssertEqual(FFmpegAudioDecoder.AudioCodec(parsing: "eac3"), .eac3)
        XCTAssertEqual(FFmpegAudioDecoder.AudioCodec(parsing: "ec3"), .eac3)
        XCTAssertEqual(FFmpegAudioDecoder.AudioCodec(parsing: "dts"), .dts)
        XCTAssertEqual(FFmpegAudioDecoder.AudioCodec(parsing: "dca"), .dts)
    }

    func testNonSurroundCodecIsNotBitstream() {
        let pcm = FFmpegAudioDecoder.AudioCodec(parsing: "pcm_s16le")
        XCTAssertFalse(pcm.isSurroundBitstream)
        if case .other = pcm { /* expected */ } else {
            XCTFail("pcm should parse to .other")
        }
    }

    // MARK: Passthrough policy

    func testNoPassthroughForMKVSurround() {
        XCTAssertFalse(FFmpegAudioDecoder.isPassthroughSupported(for: .ac3, container: "MKV"))
        XCTAssertFalse(FFmpegAudioDecoder.isPassthroughSupported(for: .eac3, container: "MKV"))
        XCTAssertFalse(FFmpegAudioDecoder.isPassthroughSupported(for: .dts, container: "MKV"))
    }

    // MARK: Decode behaviour

    func testDecodeSurroundThrowsUnsupportedFormat() async {
        let decoder = FFmpegAudioDecoder()
        let track = AudioTrackInfo(codec: "ac3", sampleRate: 48_000, channels: 6, language: nil)
        try? await decoder.attachPressureObservation()
        XCTAssertNoThrow(try decoder.configure(for: track, container: "MKV"))

        let packet = MediaPacket(
            streamIndex: 1,
            data: Data(),
            timestamp: .zero,
            duration: CMTime(value: 1, timescale: 48_000),
            isKeyFrame: true
        )

        do {
            _ = try await decoder.decode(packet)
            XCTFail("decode of MKV AC-3 surround must surface formatUnsupported")
        } catch let error as MediaError {
            XCTAssertEqual(error.code, .unsupportedFormat)
        } catch {
            XCTFail("errors must be mapped to MediaError, got \(error)")
        }
    }

    func testStubDecodeReturnsSilentFrame() async throws {
        let decoder = FFmpegAudioDecoder(configuration: .init(decodeTimeout: 5, allowStubDecode: true))
        let track = AudioTrackInfo(codec: "ac3", sampleRate: 48_000, channels: 6, language: nil)
        try decoder.configure(for: track, container: "MKV")

        let packet = MediaPacket(
            streamIndex: 1,
            data: Data(),
            timestamp: .zero,
            duration: CMTime(value: 1, timescale: 48_000),
            isKeyFrame: true
        )

        let frame = try await decoder.decode(packet)
        XCTAssertEqual(frame.format.sampleRate, 48_000)
        XCTAssertTrue(frame.buffer.allSatisfy { $0 == 0.0 })
    }

    func testCancellationMapsToMediaError() async {
        let decoder = FFmpegAudioDecoder()
        let track = AudioTrackInfo(codec: "ac3", sampleRate: 48_000, channels: 6, language: nil)
        try? decoder.configure(for: track, container: "MKV")

        let task = Task {
            let packet = MediaPacket(
                streamIndex: 1, data: Data(), timestamp: .zero,
                duration: .zero, isKeyFrame: true
            )
            return try await decoder.decode(packet)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled decode must throw")
        } catch let error as MediaError {
            XCTAssertEqual(error.kind, .cancelled)
        } catch {
            XCTFail("cancellation must map to MediaError, got \(error)")
        }
    }
}
