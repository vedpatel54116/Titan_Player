import XCTest
import CoreMedia
import CoreVideo
@testable import TitanPlayer

@MainActor
final class MediaPipelineRendererRoutingTests: XCTestCase {

    func testVideoFrameDispatchesToInjectedRenderer() async throws {
        let mock = MockFrameRenderer()
        let pipeline = MediaPipeline(videoRenderer: mock)

        let pixelBuffer = makeBlankPixelBuffer()
        let frame = MediaFrame.video(VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .sRGB
        ))

        // Trigger the routing path directly on the @MainActor.
        pipeline.processFrameForTest(frame)

        // Allow the implicit Task to settle.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mock.renderedFrames.count, 1)
        XCTAssertEqual(mock.renderedFrames.first?.pixelBuffer, pixelBuffer)
    }

    func testAudioFrameDoesNotDispatchToRenderer() {
        let mock = MockFrameRenderer()
        let pipeline = MediaPipeline(videoRenderer: mock)

        let audio = AudioFrame(
            buffer: [Float](repeating: 0, count: 256),
            format: AudioFormat(sampleRate: 44_100, channels: 2, isInterleaved: true),
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600)
        )
        pipeline.processFrameForTest(.audio(audio))
        XCTAssertEqual(mock.renderedFrames.count, 0)
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