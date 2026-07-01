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
        let view = KeyCaptureView()
        view.dispatcher = dispatcher
        view.shortcutManager = session.shortcutManager
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.shortcutManager = session.shortcutManager
    }
}

final class KeyCaptureView: NSView {
    var dispatcher: PlayerActionDispatcher?
    var shortcutManager: KeyboardShortcutManager?

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
        guard let mgr = shortcutManager, let dispatcher else {
            super.keyDown(with: event)
            return
        }
        let keyName = keyString(for: event)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for action in PlayerAction.allCases {
            guard let binding = mgr.binding(for: action) else { continue }
            if binding.key == keyName && binding.modifiers == mods {
                dispatcher.dispatch(action)
                return
            }
        }
        super.keyDown(with: event)
    }

    private func keyString(for event: NSEvent) -> String {
        switch event.specialKey {
        case .leftArrow:  return "leftarrow"
        case .rightArrow: return "rightarrow"
        case .upArrow:    return "uparrow"
        case .downArrow:  return "downarrow"
        default:
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == " " { return "space" }
            return chars
        }
    }
}
