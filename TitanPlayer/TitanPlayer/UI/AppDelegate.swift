import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls {
            Task { @MainActor in
                await SessionLocator.shared.session?.openFile(url: url)
            }
        }
    }
}
