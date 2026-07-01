import SwiftUI

/// Waveform monitor readout. Expects `WaveformData.columnLuminance` laid out as
/// `[ R[G[B[Y ] ] x kWaveformColumns (1024) x kWaveformBuckets (8) ]`, flat
/// (matches the buffer ordering emitted by `AnalysisGPURunner.runWaveform`).
struct WaveformView: View {
    let waveform: WaveformData?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.black))
            guard let w = waveform, !w.columnLuminance.isEmpty else { return }
            let columns = 1024
            let buckets = 8
            // The Y (luma) channel occupies the last quarter of `columnLuminance`.
            let yOffset = 3 * columns * buckets
            let colWidth = size.width / CGFloat(columns)
            // For each output column, pick the highest populated brightness bucket.
            for c in 0..<columns {
                var peakBucket: Int = 0
                var peakCount: Float = 0
                for b in 0..<buckets {
                    let v = w.columnLuminance[yOffset + c * buckets + b]
                    if v > peakCount {
                        peakCount = v
                        peakBucket = b
                    }
                }
                let yTop = size.height * CGFloat(buckets - peakBucket) / CGFloat(buckets)
                let rect = CGRect(x: CGFloat(c) * colWidth,
                                  y: yTop,
                                  width: max(1, colWidth),
                                  height: max(1, size.height - yTop))
                ctx.fill(Path(rect), with: .color(.white.opacity(0.85)))
            }
        }
        .frame(height: 100)
    }
}
