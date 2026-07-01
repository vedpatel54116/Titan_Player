import XCTest
import AVFAudio
import CoreVideo
@testable import TitanPlayer

final class BackendSwapTests: XCTestCase {

    // MARK: - AudioRenderer swap

    func testAudioRendererProtocolAcceptsMultipleImplementations() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        guard let placeholderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            XCTFail("Could not allocate AVAudioPCMBuffer for swap test fixture")
            return
        }

        var renderer: AudioRenderer = AVAudioEngineRenderer()
        try renderer.start()
        renderer.scheduleBuffer(placeholderBuffer, at: nil)
        renderer.volume = 0.5
        XCTAssertTrue(renderer is AVAudioEngineRenderer)

        // Now swap to the mock by reassigning the same protocol-typed variable.
        renderer = MockAudioRenderer()
        try renderer.start()
        renderer.scheduleBuffer(placeholderBuffer, at: 1.5)

        guard let mock = renderer as? MockAudioRenderer else {
            XCTFail("Expected renderer to be MockAudioRenderer after swap")
            return
        }
        XCTAssertTrue(mock.didStart)
        XCTAssertEqual(mock.scheduledBuffers.count, 1)
        XCTAssertEqual(mock.currentTime, 1.5)
    }

    // MARK: - MediaDemuxing swap

    func testMediaDemuxingProtocolAcceptsMultipleImplementations() async throws {
        guard let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4") else {
            throw XCTSkip("Fixtures/test.mp4 missing from test bundle")
        }

        var demuxer: MediaDemuxing = AVFoundationDemuxer()
        let avInfo = try await demuxer.open(url: testURL)
        demuxer.close()
        XCTAssertFalse(avInfo.videoTracks.isEmpty)

        demuxer = FFmpegDemuxer()
        let ffmpegInfo = try await demuxer.open(url: testURL)
        demuxer.close()
        XCTAssertNotNil(ffmpegInfo.format)
    }

    // MARK: - MediaDecoding swap

    func testMediaDecodingProtocolAcceptsMultipleImplementations() async throws {
        let track = VideoTrackInfo(
            codec: "h264",
            width: 1920,
            height: 1080,
            frameRate: 30.0,
            isHDR: false,
            extradata: nil
        )
        let packet = MediaPacket(
            streamIndex: 0,
            data: Data(),
            timestamp: CMTime(value: 0, timescale: 600),
            duration: CMTime(value: 16, timescale: 600),
            isKeyFrame: true
        )

        var decoder: MediaDecoding = AVFoundationDecoder()
        try decoder.configure(for: track)
        let avFrame = try await decoder.decode(packet)
        decoder.flush()

        switch avFrame {
        case .video(let v): _ = CVPixelBufferGetWidth(v.pixelBuffer)
        default: XCTFail("Expected video frame from AVFoundationDecoder after swap")
        }

        decoder = FFmpegDecoder()
        try decoder.configure(for: track)
        let ffmpegFrame = try await decoder.decode(packet)
        decoder.flush()

        switch ffmpegFrame {
        case .video(let v): _ = CVPixelBufferGetWidth(v.pixelBuffer)
        default: XCTFail("Expected video frame from FFmpegDecoder after swap")
        }
    }

    // MARK: - FrameRendering swap

    func testFrameRenderingProtocolAcceptsMultipleImplementations() async throws {
        let pixelBuffer = makeBlankPixelBuffer()
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .sRGB
        )

        var renderer: FrameRendering? = MetalRenderer()
        try await renderer?.render(frame)
        XCTAssertTrue(renderer is MetalRenderer)

        // Swap
        renderer = MockFrameRenderer()
        try await renderer?.render(frame)

        guard let mock = renderer as? MockFrameRenderer else {
            XCTFail("Expected FrameRendering to be MockFrameRenderer after swap")
            return
        }
        XCTAssertEqual(mock.renderedFrames.count, 1)
    }

    private func makeBlankPixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_32BGRA, attrs, &buffer
        )
        return buffer!
    }
}
