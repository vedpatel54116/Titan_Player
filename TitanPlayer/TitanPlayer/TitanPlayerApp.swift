import SwiftUI

@main
struct TitanPlayerApp: App {
    @StateObject private var session = PlaybackSession()
    @StateObject private var telemetry = TelemetryManager.shared

    var body: some Scene {
        WindowGroup("TitanPlayer", id: "main") {
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
                .onAppear {
                    telemetry.initialize()
                    SessionLocator.shared.attach(session)
                }
        }
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
