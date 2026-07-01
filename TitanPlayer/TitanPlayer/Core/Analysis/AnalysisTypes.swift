import Foundation
import simd

// MARK: - Histogram

struct HistogramData {
    var redBins: [UInt32]
    var greenBins: [UInt32]
    var blueBins: [UInt32]
    var lumaBins: [UInt32]

    init(binCount: Int) {
        redBins = [UInt32](repeating: 0, count: binCount)
        greenBins = [UInt32](repeating: 0, count: binCount)
        blueBins = [UInt32](repeating: 0, count: binCount)
        lumaBins = [UInt32](repeating: 0, count: binCount)
    }

    init(redBins: [UInt32], greenBins: [UInt32], blueBins: [UInt32], lumaBins: [UInt32]) {
        self.redBins = redBins
        self.greenBins = greenBins
        self.blueBins = blueBins
        self.lumaBins = lumaBins
    }

    var peak: UInt32 {
        max(
            redBins.max() ?? 0,
            greenBins.max() ?? 0,
            blueBins.max() ?? 0,
            lumaBins.max() ?? 0
        )
    }

    var totalPixels: UInt32 {
        redBins.reduce(0, +)
    }

    var binCount: Int { lumaBins.count }
}

// MARK: - Waveform

struct WaveformData {
    var columnLuminance: [Float]

    init(columnLuminance: [Float]) {
        self.columnLuminance = columnLuminance
    }
}

// MARK: - Vectorscope

struct VectorscopeData {
    var grid: [UInt32]
    let gridSize: Int

    init(gridSize: Int) {
        self.gridSize = gridSize
        self.grid = [UInt32](repeating: 0, count: gridSize * gridSize)
    }

    init(grid: [UInt32], gridSize: Int) {
        self.grid = grid
        self.gridSize = gridSize
    }

    var peak: UInt32 { grid.max() ?? 0 }
}

// MARK: - Color Sample

struct ColorSample {
    let r: Float
    let g: Float
    let b: Float
    let a: Float

    init(r: Float, g: Float, b: Float, a: Float) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    var r8: Int { Int(round(r * 255)) }
    var g8: Int { Int(round(g * 255)) }
    var b8: Int { Int(round(b * 255)) }

    var hex8Bit: String {
        String(format: "%02X%02X%02X", r8, g8, b8)
    }

    var y: Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    var cb: Float {
        -0.1688 * r - 0.3312 * g + 0.5 * b
    }

    var cr: Float {
        0.5 * r - 0.4187 * g - 0.0813 * b
    }

    var hue: Float {
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        let delta = maxVal - minVal
        guard delta > 0 else { return 0 }
        var h: Float = 0
        if maxVal == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxVal == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return h
    }

    var saturation: Float {
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        guard maxVal > 0 else { return 0 }
        return (maxVal - minVal) / maxVal
    }

    var value: Float {
        max(r, max(g, b))
    }
}
