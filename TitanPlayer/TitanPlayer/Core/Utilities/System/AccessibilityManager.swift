import Foundation
import AppKit

final class AccessibilityManager {
    static let shared = AccessibilityManager()

    private init() {}

    var isVoiceOverRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    func announce(_ message: String) {
        guard isVoiceOverRunning else { return }
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [NSAccessibility.NotificationUserInfoKey(rawValue: "AXAnnouncement"): message])
    }

    func postLayoutChanged() {
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any,
                             notification: .layoutChanged)
    }
}
