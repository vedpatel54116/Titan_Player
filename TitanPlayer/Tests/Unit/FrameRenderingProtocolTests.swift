import XCTest
import AppKit
import CoreVideo
import CoreMedia
@testable import TitanPlayer

final class FrameRenderingProtocolTests: XCTestCase {

    func testMetalRendererConformsToFrameRendering() {
        let renderer: FrameRendering? = MetalRenderer()
        XCTAssertNotNil(renderer)
    }

    func testRendererErrorSurfacesDescription() {
        let error = RendererError.deviceUnavailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Metal"))
    }

    func testMockFrameRendererConformsAndRecords() async throws {
        let mock = MockFrameRenderer()
        let renderer: FrameRendering = mock

        let frame = VideoFrame(
            pixelBuffer: makeBlankPixelBuffer(),
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .sRGB
        )
        try await renderer.render(frame)
        renderer.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 1000, minLuminance: 0))
        renderer.resetDynamicHDRParams()

        XCTAssertEqual(mock.renderedFrames.count, 1)
        XCTAssertEqual(mock.hdrMetadatas.count, 1)
        XCTAssertEqual(mock.dynamicResetCount, 1)
    }

    func testMetalRendererImplementsAllProtocolMethods() throws {
        let renderer = MetalRenderer()
        let pixelBuffer = makeBlankPixelBuffer()
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .sRGB
        )
        let exp = expectation(description: "render returns")
        Task { @MainActor in
            try? await renderer.render(frame)
            renderer.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 100, minLuminance: 0))
            renderer.resetDynamicHDRParams()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
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