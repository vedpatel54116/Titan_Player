import AppKit
import Carbon
import os

enum KeyboardLayoutMonitor {
    private static var currentLayoutID: String = ""
    private static let logger = Logger(subsystem: "com.titanplayer", category: "keyboard")

    static func detectLayout() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return }
        let layoutID = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
        if !currentLayoutID.isEmpty && layoutID != currentLayoutID {
            logger.info("Layout changed: \(self.currentLayoutID) → \(layoutID)")
        }
        currentLayoutID = layoutID
    }
}
