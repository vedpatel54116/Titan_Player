import XCTest
import Metal
@testable import TitanPlayer

@MainActor
final class VideoAnalysisManagerToggleTests: XCTestCase {
    private func makeManager() throws -> VideoAnalysisManager {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return VideoAnalysisManager(metalDevice: device)
    }

    func testInitialTogglesAllOff() throws {
        let m = try makeManager()
        XCTAssertFalse(m.waveformEnabled)
        XCTAssertFalse(m.vectorscopeEnabled)
        XCTAssertFalse(m.histogramEnabled)
        XCTAssertFalse(m.audioMeteringEnabled)
    }

    func testInitialOutputsAllNil() throws {
        let m = try makeManager()
        XCTAssertNil(m.histogram)
        XCTAssertNil(m.waveform)
        XCTAssertNil(m.vectorscope)
        XCTAssertNil(m.colorPicker)
        XCTAssertNil(m.audioMeter.metering.integratedLUFS)
    }

    func testToggleFlagsChange() throws {
        let m = try makeManager()
        m.waveformEnabled = true
        m.vectorscopeEnabled = true
        m.histogramEnabled = true
        m.audioMeteringEnabled = true
        XCTAssertTrue(m.waveformEnabled)
        XCTAssertTrue(m.vectorscopeEnabled)
        XCTAssertTrue(m.histogramEnabled)
        XCTAssertTrue(m.audioMeteringEnabled)
    }

    func testDisabledFlagsDoNotProduceOutputsEvenWithFreshTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let m = VideoAnalysisManager(metalDevice: device)
        let store = FrameStore()
        m.attach(frameStore: store)
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false))!
        store.update(tex)
        let exp = expectation(description: "publish windows")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertNil(m.histogram)
        XCTAssertNil(m.waveform)
        XCTAssertNil(m.vectorscope)
    }

    func testHistogramEnabledProducesNonNilOutput() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let m = VideoAnalysisManager(metalDevice: device)
        let store = FrameStore()
        m.attach(frameStore: store)
        m.histogramEnabled = true

        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false))!
        let data = [Float](repeating: 1.0, count: 16 * 16 * 4)
        tex.replace(region: MTLRegionMake2D(0, 0, 16, 16),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: 16 * 4 * MemoryLayout<Float>.size)
        store.update(tex)
        let exp = expectation(description: "publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
        XCTAssertNotNil(m.histogram)
    }
}
