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
        let keyName = PhysicalKeyResolver.keyString(for: event)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for action in PlayerAction.allCases {
            guard let binding = shortcutManager.binding(for: action) else { continue }
            if binding.key == keyName && binding.modifiers == mods {
                return action
            }
        }
        return nil
    }
}
