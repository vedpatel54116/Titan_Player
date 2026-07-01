import SwiftUI

/// Histogram readout. `HistogramData` carries 256-bin R/G/B/Y distributions.
struct HistogramView: View {
    let histogram: HistogramData?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.black))
            guard let h = histogram else { return }
            let maxCount = h.peak
            guard maxCount > 0 else { return }
            let bins = h.binCount
            let colWidth = size.width / CGFloat(bins)
            func plot(_ bins: [UInt32], color: Color) {
                for i in 0..<bins.count {
                    let v = CGFloat(bins[i]) / CGFloat(maxCount)
                    let height = size.height * v
                    let rect = CGRect(x: CGFloat(i) * colWidth,
                                      y: size.height - height,
                                      width: max(1, colWidth),
                                      height: height)
                    ctx.fill(Path(rect), with: .color(color.opacity(0.6)))
                }
            }
            plot(h.redBins,   color: .red)
            plot(h.greenBins, color: .green)
            plot(h.blueBins,  color: .blue)
            plot(h.lumaBins,  color: .white.opacity(0.35))
        }
        .frame(height: 100)
    }
}
