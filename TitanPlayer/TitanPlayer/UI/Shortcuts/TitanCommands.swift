import SwiftUI
import AppKit

@MainActor
final class SessionLocator {
    static let shared = SessionLocator()
    private(set) weak var session: PlaybackSession?

    var openLibraryWindow: ((URL) -> Void)?

    private init() {}

    func attach(_ session: PlaybackSession) {
        self.session = session
    }

    @MainActor
    final class MiniWindowController {
        static let shared = MiniWindowController()
        private(set) weak var window: NSWindow?

        func toggle(using viewBuilder: (PlaybackSession) -> MiniPlayerView) {
            if let existing = NSApp.windows.first(where: { $0.title == "Mini Player" }) {
                existing.close()
                return
            }
            guard let session = SessionLocator.shared.session else { return }
            let style: NSWindow.StyleMask = [.borderless, .resizable]
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                styleMask: style, backing: .buffered, defer: false)
            window.title = "Mini Player"
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isMovable = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(
                rootView: viewBuilder(session).environmentObject(session))
            window.makeKeyAndOrderFront(nil)
            self.window = window
        }
    }
}

struct TitanCommands: Commands {
    let session: PlaybackSession
    let dispatcher: PlayerActionDispatcher

    init(session: PlaybackSession) {
        self.session = session
        let side = DispatcherSideEffects(
            toggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
            toggleMiniPlayer: {
                SessionLocator.MiniWindowController.shared.toggle { session in
                    MiniPlayerView()
                }
            },
            newLibraryWindow: { TitanCommands.openLibraryPanel() },
            openFile:         { TitanCommands.openFileUsingPanel(session: session) }
        )
        self.dispatcher = PlayerActionDispatcher(session: session, sideEffects: side)
    }

    var body: some Commands {
        CommandMenu("Playback") { playbackMenu }
        CommandMenu("Window")   { windowMenu }
        CommandMenu("Aspect")   { aspectMenu }
    }

    @ViewBuilder
    private var playbackMenu: some View {
        menuButton("Play / Pause",         action: .togglePlayPause)
        menuButton("Skip Back 10 s",       action: .seekBackward10)
        menuButton("Skip Forward 10 s",    action: .seekForward10)
        Divider()
        menuButton("Mute",                 action: .toggleMute)
        menuButton("Toggle Subtitles",     action: .toggleSubtitles)
        menuButton("Toggle HDR Tone Map",  action: .toggleHDR)
        Divider()
        menuButton("Increase Rate",        action: .increasePlaybackRate)
        menuButton("Decrease Rate",        action: .decreasePlaybackRate)
        menuButton("Reset Rate (1.0×)",    action: .resetPlaybackRate)
    }

    @ViewBuilder
    private var windowMenu: some View {
        menuButton("Open File…",           action: .openFile)
        Divider()
        menuButton("Mini Player",          action: .toggleMiniPlayer)
        menuButton("New Library Window",   action: .newLibraryWindow)
        Divider()
        menuButton("Toggle Full Screen",   action: .toggleFullscreen)
    }

    @ViewBuilder
    private var aspectMenu: some View {
        menuButton("Fit",                  action: .setAspectRatioFit)
        menuButton("Fill",                 action: .setAspectRatioFill)
        menuButton("Stretch",              action: .setAspectRatioStretch)
        menuButton("Auto",                 action: .setAspectRatioAuto)
    }

    @ViewBuilder
    private func menuButton(_ title: String, action: PlayerAction) -> some View {
        let binding = session.shortcutManager.binding(for: action)
        let resolved = binding.flatMap {
            KeyEquivalentResolver.resolve(key: $0.key, modifiers: $0.modifiers)
        }
        if let resolved {
            Button(title) { dispatcher.dispatch(action) }
                .keyboardShortcut(resolved.equivalent, modifiers: resolved.modifiers)
        } else {
            Button(title) { dispatcher.dispatch(action) }
        }
    }

    static func openLibraryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            SessionLocator.shared.openLibraryWindow?(url)
        }
    }

    static func openFileUsingPanel(session: PlaybackSession) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await session.openFile(url: url) }
        }
    }
}
