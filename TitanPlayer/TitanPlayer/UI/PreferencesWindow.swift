import SwiftUI

struct PreferencesWindow: Scene {
    @EnvironmentObject var telemetry: TelemetryManager
    
    var body: some Scene {
        Window("Preferences", id: "preferences") {
            TabView {
                TelemetryPreferencesView()
                    .tabItem { Label("Privacy", systemImage: "lock") }
                ShortcutsPreferencesView()
                    .tabItem { Label("Shortcuts", systemImage: "command") }
            }
        }
    }
}
