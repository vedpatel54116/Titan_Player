import XCTest
import AppKit
import CoreMedia
import CoreVideo
import MetalKit
import simd
@testable import TitanPlayer

final class HDRPlaybackIntegrationTests: XCTestCase {

    private func makeRenderer() throws -> MetalRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment")
        }
        return try MetalRenderer.make()
    }

    func testHDRRendererPipelineCreation() throws {
        let renderer = try makeRenderer()
        XCTAssertNotNil(renderer)
    }

    func testDisplayCapabilityDetectionFlow() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available in this environment")
        }
        let detector = DisplayCapabilityDetector()
        let capabilities = detector.detectCapabilities(for: screen)
        let profile = detector.detectICCProfile(for: screen)

        XCTAssertGreaterThanOrEqual(capabilities.maxEDRLuminance, 0)
        XCTAssertTrue(ColorGamut.allCases.contains(profile.gamut))
    }

    func testHDRModeTransitions() throws {
        let renderer = try makeRenderer()

        renderer.updateHDRMode(.sdr)

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
        renderer.updateHDRMode(.hlg)
        renderer.updateHDRMode(.sdr)
    }

    func testHDRMetadataRoutingThroughHandleHDR() throws {
        let renderer = try makeRenderer()
        renderer.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 1000, minLuminance: 0))
        renderer.handleHDR(HDRMetadata(type: .hlg, maxLuminance: 1000, minLuminance: 0))
        renderer.handleHDR(HDRMetadata(type: .dolbyVision, maxLuminance: 1000, minLuminance: 0))
    }

    func testSRGBFallback() {
        let profile = ICCProfile.sRGB
        XCTAssertEqual(profile.gamut, .srgb)
        let identity = simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        )
        XCTAssertEqual(profile.matrix, identity)
    }

    func testDynamicMetadataEndToEnd() throws {
        let renderer = try makeRenderer()
        renderer.updateDynamicHDRParams(
            kneePoint: 0.6,
            compressionRatio: 0.75,
            saturationScale: 1.0,
            brightnessAdjustment: 0.0
        )
        renderer.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 1000, minLuminance: 0))
        renderer.resetDynamicHDRParams()
    }

    func testFullRenderCycleWithHDRMetadata() throws {
        let renderer = try makeRenderer()
        renderer.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 1000, minLuminance: 0))

        let frame = VideoFrame(
            pixelBuffer: makeBlankPixelBuffer(),
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .bt2020
        )
        let exp = expectation(description: "render returns")
        Task {
            try? await renderer.render(frame)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    private func makeBlankPixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault, 32, 32,
            kCVPixelFormatType_32BGRA, attrs, &buffer
        )
        return buffer!
    }
}
