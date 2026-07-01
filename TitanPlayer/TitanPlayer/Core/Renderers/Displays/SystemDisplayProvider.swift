import AppKit

final class SystemDisplayProvider: DisplayProviding {
    func currentScreens() -> [NSScreen] {
        NSScreen.screens
    }
}
