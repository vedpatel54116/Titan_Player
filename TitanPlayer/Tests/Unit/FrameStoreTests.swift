import XCTest
import Metal
@testable import TitanPlayer

@MainActor
final class FrameStoreTests: XCTestCase {
    func testInitialFrameIDIsZeroAndTextureNil() {
        let store = FrameStore()
        XCTAssertEqual(store.frameID, 0)
        XCTAssertNil(store.latestTexture)
    }

    func testUpdateBumpsFrameIDAndStoresTexture() {
        let store = FrameStore()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false))
        store.update(tex)
        XCTAssertEqual(store.frameID, 1)
        XCTAssertTrue(store.latestTexture === tex)
    }

    func testFrameIDIsMonotonic() {
        let store = FrameStore()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false))
        store.update(tex)
        store.update(tex)
        store.update(tex)
        XCTAssertEqual(store.frameID, 3)
    }
}
