import XCTest
import MetalKit
@testable import TitanPlayer

final class MetalRendererTests: XCTestCase {
    func testMetalRendererInitialization() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let renderer = MetalRenderer(metalView: metalView)
        
        XCTAssertNotNil(renderer)
    }
    
    func testHDRModeUpdate() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(metalView: metalView) else {
            XCTSkip("Renderer failed to initialize")
            return
        }
        
        let hdr10Metadata = HDR10Metadata(
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
        
        renderer.updateHDRMode(.hdr10(hdr10Metadata))
    }
    
    func testDisplayCapabilitiesUpdate() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(metalView: metalView) else {
            XCTSkip("Renderer failed to initialize")
            return
        }
        
        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }
        
        renderer.updateDisplayCapabilities(for: screen)
    }
}
