import XCTest
import Metal
@testable import TitanPlayer

final class AnalyzerKernelTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return d
    }

    func testGPURunnerInitializesWithDevice() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        XCTAssertNotNil(runner)
    }

    func testHistogramKernelGradients() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        try XCTSkipUnless(runner.isReady(for: .histogram), "kernelHistogram not found")

        let w = 256, h = 256
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false))!
        // Vertical grayscale ramp: row 0 = (0,0,0), row h-1 = (1,1,1)
        var data = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let g = Float(y) / Float(h - 1)
            for x in 0..<w {
                let idx = (y * w + x) * 4
                data[idx + 0] = g
                data[idx + 1] = g
                data[idx + 2] = g
                data[idx + 3] = 1.0
            }
        }
        let bytesPerRow = w * 4 * MemoryLayout<Float>.size
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)

        let hist = runner.runHistogram(texture: tex)
        XCTAssertNotNil(hist)
        // Each of 256 luma bins should contain ≈ w = 256 pixels (within rounding).
        XCTAssertEqual(hist?.lumaBins.first ?? 0, UInt32(w * h / 256), accuracy: UInt32(w * h / 8))
        for c in 0..<3 {
            XCTAssertEqual(hist?.redBins[c]   ?? 0, UInt32(w * h / 256), accuracy: UInt32(w * h / 8))
            XCTAssertEqual(hist?.greenBins[c] ?? 0, UInt32(w * h / 256), accuracy: UInt32(w * h / 8))
            XCTAssertEqual(hist?.blueBins[c]  ?? 0, UInt32(w * h / 256), accuracy: UInt32(w * h / 8))
        }
    }

    func testVectorscopeKernelNonZeroOnSaturatedPixels() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        try XCTSkipUnless(runner.isReady(for: .vectorscope), "kernelVectorscope not found")

        let w = 16, h = 16
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false))!
        var data = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let isRed = (x < w / 2)
                data[idx + 0] = isRed ? 1.0 : 0.0
                data[idx + 1] = 0.0
                data[idx + 2] = isRed ? 0.0 : 1.0
                data[idx + 3] = 1.0
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: w * 4 * MemoryLayout<Float>.size)
        let vecs = runner.runVectorscope(texture: tex)
        XCTAssertNotNil(vecs)
        XCTAssertGreaterThan(vecs?.peak ?? 0, 0)
    }

    func testWaveformKernelGradients() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        try XCTSkipUnless(runner.isReady(for: .waveform), "kernelWaveform not found")

        let w = 256, h = 256
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false))!
        var data = [Float](repeating: 0, count: w * h * 4)
        // Horizontal gradient: black on the left, white on the right.
        for y in 0..<h {
            for x in 0..<w {
                let v = Float(x) / Float(w - 1)
                let idx = (y * w + x) * 4
                data[idx + 0] = v
                data[idx + 1] = v
                data[idx + 2] = v
                data[idx + 3] = 1.0
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: w * 4 * MemoryLayout<Float>.size)
        guard let wave = runner.runWaveform(texture: tex) else {
            XCTFail("runner returned nil"); return
        }
        XCTAssertEqual(wave.columnLuminance.count, 1024 * 8 * 4)
    }

    func testColorPickerSamplesExactPixel() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        try XCTSkipUnless(runner.isReady(for: .colorPicker), "kernelColorPicker not found")
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false))!
        var data = [Float](repeating: 0, count: 16 * 16 * 4)
        // (3, 5) = pure green
        for r in 0..<16 {
            for c in 0..<16 {
                let idx = (r * 16 + c) * 4
                data[idx + 0] = 0
                data[idx + 1] = (c == 3 && r == 5) ? 1.0 : 0.0
                data[idx + 2] = 0
                data[idx + 3] = 1.0
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, 16, 16),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: 16 * 4 * MemoryLayout<Float>.size)
        let sample = runner.samplePixel(texture: tex, col: 3, row: 5)
        XCTAssertEqual(sample.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(sample.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(sample.z, 0.0, accuracy: 0.001)
    }
}
