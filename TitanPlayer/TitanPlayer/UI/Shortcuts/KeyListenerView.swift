import SwiftUI
import AppKit

struct KeyListenerView: NSViewRepresentable {
    let session: PlaybackSession
    let dispatcher: PlayerActionDispatcher

    init(session: PlaybackSession) {
        self.session = session
        self.dispatcher = PlayerActionDispatcher(session: session)
    }

    func makeNSView(context: Context) -> KeyCaptureView {
        let router = KeyEventRouter(shortcutManager: session.shortcutManager)
        let view = KeyCaptureView()
        view.dispatcher = dispatcher
        view.router = router
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.router = KeyEventRouter(shortcutManager: session.shortcutManager)
    }
}

final class KeyCaptureView: NSView {
    var dispatcher: PlayerActionDispatcher?
    var router: KeyEventRouter?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let router, let dispatcher else {
            super.keyDown(with: event)
            return
        }
        if let action = router.action(for: event) {
            dispatcher.dispatch(action)
            return
        }
        super.keyDown(with: event)
    }
}
