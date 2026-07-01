import XCTest
import Metal
import MetalKit
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class MetalRendererMultiTargetTests: XCTestCase {

    private func makeRenderer() throws -> MetalRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable")
        }
        return try MetalRenderer.make()
    }

    func testAddAndRemoveDisplayTarget() throws {
        let renderer = try makeRenderer()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let caps = DisplayCapabilities(
            supportsHDR: true, supportsEDR: true,
            maxEDRLuminance: 1600, colorGamut: .bt2020
        )

        renderer.addDisplayTarget(
            stableID: "cgdid:2",
            layer: layer,
            capabilities: caps,
            iccProfile: ICCProfile.sRGB
        )

        renderer.removeDisplayTarget(stableID: "cgdid:2")
    }

    func testUpdateDisplayCapabilitiesForTarget() throws {
        let renderer = try makeRenderer()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let capsSDR = DisplayCapabilities(
            supportsHDR: false, supportsEDR: false,
            maxEDRLuminance: 0, colorGamut: .srgb
        )
        let capsHDR = DisplayCapabilities(
            supportsHDR: true, supportsEDR: true,
            maxEDRLuminance: 1600, colorGamut: .bt2020
        )

        renderer.addDisplayTarget(
            stableID: "cgdid:2",
            layer: layer,
            capabilities: capsSDR,
            iccProfile: ICCProfile.sRGB
        )

        renderer.updateDisplayCapabilities(
            for: "cgdid:2",
            capabilities: capsHDR,
            iccProfile: ICCProfile(gamut: .bt2020, matrix: ICCProfile.sRGB.matrix)
        )
    }

    func testRenderWithMultipleTargetsDoesNotThrow() throws {
        let renderer = try makeRenderer()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let caps = DisplayCapabilities(
            supportsHDR: false, supportsEDR: false,
            maxEDRLuminance: 0, colorGamut: .srgb
        )

        renderer.addDisplayTarget(
            stableID: "cgdid:2",
            layer: layer,
            capabilities: caps,
            iccProfile: ICCProfile.sRGB
        )

        let pixelBuffer = makeBlankPixelBuffer()
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
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

        renderer.removeDisplayTarget(stableID: "cgdid:2")
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
