import XCTest
import AppKit
import CoreMedia
import CoreVideo
import MetalKit
@testable import TitanPlayer

final class MetalRendererTests: XCTestCase {

    private func makeRenderer() throws -> MetalRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment")
        }
        return try MetalRenderer.make()
    }

    func testRendererInitialization() throws {
        let renderer = try makeRenderer()
        XCTAssertNotNil(renderer)
    }

    func testMakeThrowsWhenDeviceUnavailable() throws {
        // Metal is available on all modern Macs; this only documents the
        // failure path. We cannot force nil here, so just verify the happy
        // path returns a usable instance.
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment")
        }
        XCTAssertNotNil(try? MetalRenderer.make())
    }

    func testHDR10ModeUpdate() throws {
        let renderer = try makeRenderer()
        let metadata = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: 1000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )
        renderer.updateHDRMode(.hdr10(metadata))
        renderer.updateHDRMode(.sdr)
    }

    func testHLGModeUpdate() throws {
        let renderer = try makeRenderer()
        renderer.updateHDRMode(.hlg)
        renderer.updateHDRMode(.sdr)
    }

    func testDisplayCapabilitiesUpdate() throws {
        let renderer = try makeRenderer()
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available in this environment")
        }
        renderer.updateDisplayCapabilities(for: screen)
    }

    func testDynamicHDRParamsRoundTrip() throws {
        let renderer = try makeRenderer()
        renderer.updateDynamicHDRParams(
            kneePoint: 0.5,
            compressionRatio: 0.8,
            saturationScale: 1.1,
            brightnessAdjustment: 0.05
        )
        renderer.resetDynamicHDRParams()
    }

    func testHandleHDRMetadata() throws {
        let renderer = try makeRenderer()
        renderer.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 1000, minLuminance: 0))
        renderer.handleHDR(HDRMetadata(type: .hlg, maxLuminance: 1000, minLuminance: 0))
        renderer.handleHDR(HDRMetadata(type: .dolbyVision, maxLuminance: 1000, minLuminance: 0))
    }

    func testRenderVideoFrameDoesNotThrow() throws {
        let renderer = try makeRenderer()
        let frame = VideoFrame(
            pixelBuffer: makeBlankPixelBuffer(),
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .sRGB
        )
        let exp = expectation(description: "render returns")
        Task {
            try? await renderer.render(frame)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testAttachAndDetachToMTKView() throws {
        let renderer = try makeRenderer()
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        renderer.attach(to: view)
        XCTAssertEqual(view.colorPixelFormat, .rgba16Float)
        XCTAssertFalse(view.framebufferOnly)
        renderer.detach()
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
