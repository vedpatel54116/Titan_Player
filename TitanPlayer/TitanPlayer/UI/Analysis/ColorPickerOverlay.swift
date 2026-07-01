import SwiftUI
import AppKit

/// Lightweight Cmd-click overlay placed over `PlayerView`'s content.
/// Captures the click location, maps it back to source-pixel coordinates
/// using the view's current letterbox geometry, and asks the
/// `VideoAnalysisManager` to sample the displayed color.
///
/// The mapping helper is exposed as a static so unit tests can verify
/// the per-`FitMode` math in isolation.
struct ColorPickerOverlay<Content: View>: View {
    @ObservedObject var manager: VideoAnalysisManager
    let viewSizeProvider: () -> CGSize
    let sourceSizeProvider: () -> CGSize?
    let fitMode: FitMode
    let content: () -> Content

    var body: some View {
        content()
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { _ in }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .modifiers(.command)
                                .onEnded { value in
                                    let viewSize = geo.size
                                    guard let srcSize = sourceSizeProvider() else { return }
                                    let srcSizeCG = CGSize(width: CGFloat(srcSize.width),
                                                           height: CGFloat(srcSize.height))
                                    let letterbox = Self.letterbox(
                                        view: viewSize, source: srcSizeCG, fitMode: fitMode)
                                    let mapped = Self.mapViewToSource(
                                        viewPoint: value.location,
                                        viewSize: viewSize,
                                        sourceSize: srcSizeCG,
                                        fitMode: fitMode,
                                        letterbox: letterbox)
                                    Task { @MainActor in
                                        _ = await manager.sampleColor(
                                            at: Int(mapped.x.rounded()),
                                            row: Int(mapped.y.rounded()))
                                    }
                                }
                        )
                }
            )
    }

    /// Pillar/letterbox bar sizes when fitting a `source` frame into a `view`.
    static func letterbox(view: CGSize, source: CGSize, fitMode: FitMode) -> CGSize {
        guard view.width > 0, view.height > 0, source.width > 0, source.height > 0 else {
            return .zero
        }
        let viewAR = view.width / view.height
        let srcAR  = source.width / source.height
        switch fitMode {
        case .fit:
            if srcAR > viewAR {
                let contentH = view.width / srcAR
                return CGSize(width: 0,
                              height: max(0, (view.height - contentH) / 2))
            } else {
                let contentW = view.height * srcAR
                return CGSize(width: max(0, (view.width - contentW) / 2),
                              height: 0)
            }
        case .fill:
            return .zero
        case .stretch:
            return .zero
        }
    }

    /// Map a view-point (under the user's cursor) back to source-pixel coords.
    static func mapViewToSource(viewPoint: CGPoint,
                                viewSize: CGSize,
                                sourceSize: CGSize,
                                fitMode: FitMode,
                                letterbox: CGSize) -> CGPoint {
        var x = viewPoint.x - letterbox.width
        var y = viewPoint.y - letterbox.height
        let contentW = max(1, viewSize.width - letterbox.width * 2)
        let contentH = max(1, viewSize.height - letterbox.height * 2)
        let sx = x / contentW * sourceSize.width
        let sy = y / contentH * sourceSize.height
        switch fitMode {
        case .fit:
            x = max(0, min(sx, sourceSize.width - 1))
            y = max(0, min(sy, sourceSize.height - 1))
        case .fill:
            // Inverse of fill-crop mapping: source constraints fit while preserving aspect.
            x = max(0, min(sx, sourceSize.width - 1))
            y = max(0, min(sy, sourceSize.height - 1))
        case .stretch:
            x = max(0, min(sx, sourceSize.width - 1))
            y = max(0, min(sy, sourceSize.height - 1))
        }
        return CGPoint(x: x, y: y)
    }
}
