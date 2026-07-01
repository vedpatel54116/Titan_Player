import XCTest
import Metal
import MetalKit
@testable import TitanPlayer

final class DisplayRenderTargetTests: XCTestCase {

    private func makeDevice() -> MTLDevice? {
        MTLCreateSystemDefaultDevice()
    }

    func testTargetCreationStoresProperties() throws {
        guard let device = makeDevice() else {
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
        let icc = ICCProfile.sRGB
        let buffer = device.makeBuffer(length: MemoryLayout<HDRUniforms>.size, options: .storageModeShared)!

        let target = DisplayRenderTarget(
            stableID: "cgdid:1",
            layer: layer,
            capabilities: caps,
            iccProfile: icc,
            hdrUniformsBuffer: buffer,
            toneMappedTexture: nil,
            renderPipelineState: nil
        )

        XCTAssertEqual(target.stableID, "cgdid:1")
        XCTAssertTrue(target.capabilities.supportsHDR)
        XCTAssertEqual(target.capabilities.maxEDRLuminance, 1600)
        XCTAssertNil(target.toneMappedTexture)
    }

    func testMultipleTargetsHaveIndependentUniforms() throws {
        guard let device = makeDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let capsHDR = DisplayCapabilities(
            supportsHDR: true, supportsEDR: true,
            maxEDRLuminance: 1600, colorGamut: .bt2020
        )
        let capsSDR = DisplayCapabilities(
            supportsHDR: false, supportsEDR: false,
            maxEDRLuminance: 0, colorGamut: .srgb
        )
        let icc = ICCProfile.sRGB

        let buf1 = device.makeBuffer(length: MemoryLayout<HDRUniforms>.size, options: .storageModeShared)!
        let buf2 = device.makeBuffer(length: MemoryLayout<HDRUniforms>.size, options: .storageModeShared)!

        var u1 = HDRUniforms(
            hdrMode: 1, isHDRDisplay: 1, colorMatrix: icc.matrix,
            maxLuminance: 1600, minLuminance: 0.001,
            maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400,
            kneePoint: 0, compressionRatio: 1, saturationScale: 1,
            brightnessAdjustment: 0, useDynamicMetadata: 0
        )
        var u2 = HDRUniforms(
            hdrMode: 0, isHDRDisplay: 0, colorMatrix: icc.matrix,
            maxLuminance: 0, minLuminance: 0,
            maxContentLightLevel: 0, maxFrameAverageLightLevel: 0,
            kneePoint: 0, compressionRatio: 1, saturationScale: 1,
            brightnessAdjustment: 0, useDynamicMetadata: 0
        )

        memcpy(buf1.contents(), &u1, MemoryLayout<HDRUniforms>.size)
        memcpy(buf2.contents(), &u2, MemoryLayout<HDRUniforms>.size)

        let target1 = DisplayRenderTarget(
            stableID: "cgdid:1", layer: layer, capabilities: capsHDR,
            iccProfile: icc, hdrUniformsBuffer: buf1
        )
        let target2 = DisplayRenderTarget(
            stableID: "cgdid:2", layer: layer, capabilities: capsSDR,
            iccProfile: icc, hdrUniformsBuffer: buf2
        )

        XCTAssertTrue(target1.hdrUniformsBuffer !== target2.hdrUniformsBuffer)

        let read1 = target1.hdrUniformsBuffer.contents().assumingMemoryBound(to: HDRUniforms.self).pointee
        let read2 = target2.hdrUniformsBuffer.contents().assumingMemoryBound(to: HDRUniforms.self).pointee
        XCTAssertEqual(read1.isHDRDisplay, 1)
        XCTAssertEqual(read2.isHDRDisplay, 0)
    }
}
