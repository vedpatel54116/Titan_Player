import SwiftUI
import AVKit

/// NSViewRepresentable wrapper that renders video via AVPlayer's built-in
/// AVPlayerView. Used in compatibility mode when the custom Metal pipeline
/// fails to open a file.
struct AVPlayerViewWrapper: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
