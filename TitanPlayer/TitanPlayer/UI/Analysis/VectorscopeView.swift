import SwiftUI

/// Vectorscope readout. `VectorscopeData.grid` is a 256×256 scatter of
/// Cb (x) / Cr (y) bin counts; rendering uses normalized intensity.
struct VectorscopeView: View {
    let vectorscope: VectorscopeData?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.black))
            // Axes (Cb=0 / Cr=0 cross-hair)
            let cx = size.width / 2
            let cy = size.height / 2
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: cy))
            axes.addLine(to: CGPoint(x: size.width, y: cy))
            axes.move(to: CGPoint(x: cx, y: 0))
            axes.addLine(to: CGPoint(x: cx, y: size.height))
            ctx.stroke(axes, with: .color(.gray.opacity(0.4)), lineWidth: 1)
            guard let v = vectorscope else { return }
            guard v.grid.count == v.gridSize * v.gridSize else { return }
            let maxCount: UInt32 = v.grid.max() ?? 0
            guard maxCount > 0 else { return }
            for gy in 0..<v.gridSize {
                for gx in 0..<v.gridSize {
                    let c = v.grid[gy * v.gridSize + gx]
                    if c == 0 { continue }
                    let intensity = min(1.0, Double(c) / Double(maxCount))
                    let px = size.width * CGFloat(gx) / CGFloat(v.gridSize)
                    let py = size.height * CGFloat(gy) / CGFloat(v.gridSize)
                    let dot = CGRect(x: px - 1, y: py - 1, width: 2, height: 2)
                    ctx.fill(Path(ellipseIn: dot), with: .color(.white.opacity(intensity)))
                }
            }
        }
        .frame(width: 200, height: 200)
    }
}
