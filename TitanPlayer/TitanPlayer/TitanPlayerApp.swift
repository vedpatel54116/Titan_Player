import SwiftUI

@main
struct TitanPlayerApp: App {
    @StateObject private var session = PlaybackSession()

    var body: some Scene {
        WindowGroup("TitanPlayer", id: "main") {
            ContentView()
                .environmentObject(session)
                .onAppear { SessionLocator.shared.attach(session) }
        }
        .commands { TitanCommands(session: session) }

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
    }
}
