import SwiftUI

struct SeekSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void
    
    @State private var isDragging = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)
                
                // Progress
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: progressWidth(in: geometry), height: 4)
                
                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .offset(x: thumbOffset(in: geometry))
                    .shadow(radius: 2)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        onEditingChanged(true)
                        updateValue(from: drag.location, in: geometry)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 20)
    }
    
    private func progressWidth(in geometry: GeometryProxy) -> CGFloat {
        let proportion = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return geometry.size.width * CGFloat(proportion)
    }
    
    private func thumbOffset(in geometry: GeometryProxy) -> CGFloat {
        progressWidth(in: geometry) - 6
    }
    
    private func updateValue(from location: CGPoint, in geometry: GeometryProxy) {
        let proportion = max(0, min(1, location.x / geometry.size.width))
        value = range.lowerBound + (range.upperBound - range.lowerBound) * proportion
    }
}
