import XCTest
import MetalKit
@testable import TitanPlayer

final class HDRPlaybackIntegrationTests: XCTestCase {
    func testHDRRendererPipelineCreation() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        let renderer = MetalRenderer(metalView: metalView)
        
        XCTAssertNotNil(renderer)
    }
    
    func testDisplayCapabilityDetectionFlow() {
        let detector = DisplayCapabilityDetector()
        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }
        
        let capabilities = detector.detectCapabilities(for: screen)
        let profile = detector.detectICCProfile(for: screen)
        
        XCTAssertTrue(capabilities.maxEDRLuminance >= 0)
        XCTAssertTrue(ColorGamut.allCases.contains(profile.gamut))
    }
    
    func testHDRModeTransitions() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(metalView: metalView) else {
            XCTSkip("Renderer failed to initialize")
            return
        }
        
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
}
