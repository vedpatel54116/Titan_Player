import XCTest
import simd
@testable import TitanPlayer

final class AnalysisTypesTests: XCTestCase {

    // MARK: - HistogramData

    func testHistogramDataDefaultBinsAreZero() {
        let data = HistogramData(binCount: 256)
        XCTAssertEqual(data.redBins.count, 256)
        XCTAssertEqual(data.greenBins.count, 256)
        XCTAssertEqual(data.blueBins.count, 256)
        XCTAssertEqual(data.lumaBins.count, 256)
        XCTAssertTrue(data.redBins.allSatisfy { $0 == 0 })
        XCTAssertTrue(data.lumaBins.allSatisfy { $0 == 0 })
    }

    func testHistogramDataPeakReturnsMaxBinValue() {
        var data = HistogramData(binCount: 8)
        data.redBins = [0, 5, 10, 3, 0, 0, 0, 0]
        XCTAssertEqual(data.peak, 10)
    }

    func testHistogramDataTotalPixelCount() {
        var data = HistogramData(binCount: 4)
        data.redBins = [10, 20, 30, 40]
        XCTAssertEqual(data.totalPixels, 100)
    }

    // MARK: - WaveformData

    func testWaveformDataStoresLuminancePerColumn() {
        let columns: [Float] = [0.1, 0.5, 0.9]
        let data = WaveformData(columnLuminance: columns)
        XCTAssertEqual(data.columnLuminance.count, 3)
        XCTAssertEqual(data.columnLuminance[1], 0.5, accuracy: 0.001)
    }

    func testWaveformDataEmptyHasZeroColumns() {
        let data = WaveformData(columnLuminance: [])
        XCTAssertTrue(data.columnLuminance.isEmpty)
    }

    // MARK: - VectorscopeData

    func testVectorscopeDataDefaultGridIsZero() {
        let data = VectorscopeData(gridSize: 256)
        XCTAssertEqual(data.grid.count, 256 * 256)
        XCTAssertTrue(data.grid.allSatisfy { $0 == 0 })
    }

    func testVectorscopeDataPeakComputesMax() {
        var data = VectorscopeData(gridSize: 4)
        data.grid[5] = 42
        XCTAssertEqual(data.peak, 42)
    }

    // MARK: - ColorSample

    func testColorSampleRGBToYCbCrConversion() {
        let sample = ColorSample(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        XCTAssertEqual(sample.y, 0.2126, accuracy: 0.001)
        XCTAssertEqual(sample.cb, 0.5, accuracy: 0.01)
        XCTAssertEqual(sample.cr, 0.5, accuracy: 0.01)
    }

    func testColorSampleWhiteYIsOne() {
        let sample = ColorSample(r: 1.0, g: 1.0, b: 1.0, a: 1.0)
        XCTAssertEqual(sample.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(sample.cb, 0.0, accuracy: 0.01)
        XCTAssertEqual(sample.cr, 0.0, accuracy: 0.01)
    }

    func testColorSampleBlackYIsZero() {
        let sample = ColorSample(r: 0.0, g: 0.0, b: 0.0, a: 1.0)
        XCTAssertEqual(sample.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(sample.cb, 0.0, accuracy: 0.01)
        XCTAssertEqual(sample.cr, 0.0, accuracy: 0.01)
    }

    func testColorSampleHexRepresentation() {
        let sample = ColorSample(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        XCTAssertEqual(sample.hex8Bit, "FF0000")
    }

    func testColorSampleHSVRedIsZeroHue() {
        let sample = ColorSample(r: 1.0, g: 0.0, b: 0.0, a: 1.0)
        XCTAssertEqual(sample.hue, 0.0, accuracy: 0.001)
        XCTAssertEqual(sample.saturation, 1.0, accuracy: 0.001)
        XCTAssertEqual(sample.value, 1.0, accuracy: 0.001)
    }

    func testColorSampleHSVGreenIs120Degrees() {
        let sample = ColorSample(r: 0.0, g: 1.0, b: 0.0, a: 1.0)
        XCTAssertEqual(sample.hue, 120.0, accuracy: 0.001)
        XCTAssertEqual(sample.saturation, 1.0, accuracy: 0.001)
        XCTAssertEqual(sample.value, 1.0, accuracy: 0.001)
    }

    func testColorSample8BitValues() {
        let sample = ColorSample(r: 0.5, g: 0.25, b: 0.75, a: 1.0)
        XCTAssertEqual(sample.r8, 128)
        XCTAssertEqual(sample.g8, 64)
        XCTAssertEqual(sample.b8, 191)
    }
}
