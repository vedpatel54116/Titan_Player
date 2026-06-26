import XCTest
import MetalKit
@testable import TitanPlayer

final class MetalRendererTests: XCTestCase {
    func testParameterlessInitDoesNotRequireView() {
        let renderer = MetalRenderer()
        XCTAssertNotNil(
            renderer,
            "MetalRenderer should construct without a view (attach is separate)"
        )
    }

    func testAttachToViewEstablishesDelegate() {
        guard let renderer = MetalRenderer() else {
            XCTSkip("Metal device unavailable")
            return
        }
        let view = MTKView()
        renderer.attach(to: view)
        XCTAssertTrue(view.delegate === renderer)
    }

    func testMakeFactoryThrowsOnFailure() {
        // Happy path: should succeed in CI; environments without Metal will throw.
        do {
            _ = try MetalRenderer.make()
        } catch RendererError.deviceUnavailable {
            // acceptable in headless environments
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHDRModeUpdate() {
        guard let renderer = MetalRenderer() else {
            XCTSkip("Metal device unavailable")
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
        guard let renderer = MetalRenderer() else {
            XCTSkip("Metal device unavailable")
            return
        }

        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }

        renderer.updateDisplayCapabilitiesSynchronously(for: screen)
    }
}
