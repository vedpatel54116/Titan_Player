import XCTest

/// Shared utilities for launching the TitanPlayer macOS app from an
/// XCUITest target with a specific fixture pre-loaded.
enum UIAppLauncher {
    /// Launch the app with the given fixture name passed via launch arguments.
    /// The app implementation inspects `CommandLine.arguments` for
    /// `--fixture <name>` and resolves it from `Tests/Fixtures/`.
    @discardableResult
    static func launch(fixtureName: String? = nil, timeout: TimeInterval = 30) -> XCUIApplication {
        let app = XCUIApplication()
        if let name = fixtureName {
            app.launchArguments += ["--fixture", name]
        }
        app.launchAndWait(timeout: timeout)
        return app
    }
}

extension XCUIApplication {
    /// Launch synchronously with a timeout that respects test timeouts.
    func launchAndWait(timeout: TimeInterval) {
        let predicate = NSPredicate(format: "exists == true AND state == runningForeground")
        _ = self.wait(for: [predicate], timeout: timeout)
    }
}
