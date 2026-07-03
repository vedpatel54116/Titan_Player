import SwiftUI

@main
struct TitanPlayerApp: App {
    @StateObject private var session = PlaybackSession()
    @StateObject private var telemetry = TelemetryManager.shared

    var body: some Scene {
        WindowGroup("Titan Player", id: "main") {
            ContentView()
                .environmentObject(session)
                .environmentObject(telemetry)
                .sheet(isPresented: Binding(
                    get: { telemetry.needsConsentPrompt },
                    set: { _ in }
                )) {
                    PrivacyConsentDialog()
                        .environmentObject(telemetry)
                }
                .alert(
                    "Player Engine Error",
                    isPresented: Binding(
                        get: { session.initializationError != nil },
                        set: { if !$0 { session.initializationError = nil } }
                    )
                ) {
                    Button("OK") { session.initializationError = nil }
                    Button("Restart") { NSApplication.shared.terminate(nil) }
                } message: {
                    Text(session.initializationError ?? "Failed to initialize player engine. Please restart the app.")
                }
                .onAppear {
                    telemetry.initialize()
                    // Session is attached in PlaybackSession.init
                }
        }
        .defaultSize(width: 960, height: 540)
        .commands {
            TitanCommands(session: session)
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "preferences" }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        // Open preferences via menu action
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .environmentObject(session)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 180)

        WindowGroup("Library", id: "library", for: URL.self) { $folderURL in
            LibraryWindowView(rootFolder: folderURL)
                .environmentObject(session)
        }
        
        PreferencesWindow()
            .environmentObject(telemetry)
    }
}
