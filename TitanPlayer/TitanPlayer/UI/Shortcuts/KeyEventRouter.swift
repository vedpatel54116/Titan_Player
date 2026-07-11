import AppKit

/// Single source of truth for resolving an `NSEvent` to a `PlayerAction`.
///
/// **Capture mechanism note:** The `PlaybackSession` local monitor
/// (`NSEvent.addLocalMonitorForEvents`) is authoritative — it intercepts
/// key-down events *before* the first-responder chain.  `KeyCaptureView`
/// keeps a thin `action(for:)` call as a fallback for the rare case where
/// the local monitor is not attached (e.g. during teardown) or the event
/// arrives via the responder chain only.
@MainActor
struct KeyEventRouter {
    let shortcutManager: KeyboardShortcutManager

    /// Resolve `event` to the matching `PlayerAction`, or `nil` if no
    /// binding matches.
    func action(for event: NSEvent) -> PlayerAction? {
        if isFirstResponderTextEditing(event: event) { return nil }

        let code = event.keyCode
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for action in PlayerAction.allCases {
            guard let binding = shortcutManager.binding(for: action) else { continue }
            if binding.keyCode == code && binding.modifiers == mods {
                return action
            }
        }
        return nil
    }

    /// Returns `true` when the event's window has a text-editing control as
    /// first responder (NSTextView, NSTextField field editor, or any
    /// NSTextInputClient).  In that case the key event should pass through
    /// to the text system instead of being intercepted as a shortcut.
    private func isFirstResponderTextEditing(event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        // NSTextView covers both plain text views and NSTextField's
        // shared field editor (which is an NSTextView subclass).
        if responder is NSTextView { return true }
        // Any view that conforms to NSTextInputClient is participating
        // in text input — let the event through.
        if responder is NSTextInputClient { return true }
        return false
    }
}
