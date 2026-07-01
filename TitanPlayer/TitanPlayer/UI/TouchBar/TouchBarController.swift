import AppKit
import SwiftUI

@MainActor
final class TouchBarController: NSObject {
    weak var session: PlaybackSession?
    var openMini: () -> Void = {}
    var newLibraryWindow: () -> Void = {}

    init(session: PlaybackSession) {
        self.session = session
        super.init()
    }

    @objc func togglePlayPause() {
        session?.togglePlayPause()
    }

    @objc func skipBackward() {
        guard let session else { return }
        Task { await session.seekBackward() }
    }

    @objc func skipForward() {
        guard let session else { return }
        Task { await session.seekForward() }
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        session?.setVolume(sender.floatValue)
    }

    @objc func openMiniPlayer() {
        openMini()
    }

    @objc func openLibraryAction() {
        newLibraryWindow()
    }

    @objc func seekViaScrubber(_ sender: NSScrubber) {
        guard let session else { return }
        let selected = sender.selectedIndex
        guard selected >= 0 else { return }
        let total = max(1, sender.numberOfItems - 1)
        let pct = Double(selected) / Double(total)
        let duration = max(0, session.duration)
        let target = duration * pct
        Task { await session.seek(to: target) }
    }
}
