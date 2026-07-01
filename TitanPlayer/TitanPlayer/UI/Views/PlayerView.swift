import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PlayerView: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var showControls = true
    @State private var hideTime: Date?
    @State private var hideTimer: Timer?
    @State private var cursorHidden = false

    var body: some View {
        ZStack {
            // Cmd-click overlay for the frame-accurate color picker.
            // Sits beneath subtitle/control layers so it captures view clicks
            // without interfering with subtitle hit-testing or the control bar.
            ColorPickerOverlay(
                manager: session.analysis,
                viewSizeProvider: { .zero },  // unused; we resolve from GeometryReader
                sourceSizeProvider: { session.analysis.latestTextureSize },
                fitMode: session.effectiveFitMode
            ) {
                VideoContentView()
                    .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
                    .onTapGesture { revealControls() }
            }

            SubtitleOverlay(
                events: session.currentSubtitleEvents,
                hasMetalBitmap: session.currentSubtitleBitmap != nil
            )

            VStack {
                Spacer()
                if showControls {
                    ControlBar()
                        .transition(.opacity)
                }
            }

            Color.clear
                .background {
                    KeyListenerView(session: session)
                }
                .background(TouchBarProvider(session: session))
        }
        .accessibilityIdentifier("playerView.root")
        .onAppear { revealControls() }
        .onHover { _ in revealControls() }
        .onChange(of: showControls) { visible in
            if visible { unhideCursor() } else if session.playState == .playing { hideCursor() }
        }
        .onChange(of: session.playState) { newstate in
            if newstate == .playing {
                startHideTimer()
            } else {
                cancelHideTimer()
                withAnimation { showControls = true }
                unhideCursor()
            }
        }
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func revealControls() {
        withAnimation { showControls = true }
        hideTimer?.invalidate()
        if cursorHidden { unhideCursor() }
        if session.playState == .playing {
            hideTime = Date().addingTimeInterval(3)
            hideTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
                guard let hideTime, Date() >= hideTime, session.playState == .playing else { return }
                withAnimation { showControls = false }
                hideTimer?.invalidate()
                hideTimer = nil
            }
        } else {
            hideTime = nil
        }
    }

    private func startHideTimer() { revealControls() }
    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
        hideTime = nil
    }

    private func hideCursor() { cursorHidden = true; NSCursor.hide() }
    private func unhideCursor() { if cursorHidden { cursorHidden = false; NSCursor.unhide() } }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in await session.openFile(url: url) }
        }
        return true
    }
}

struct VideoContentView: View {
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        ZStack {
            Color.black
            switch session.playState {
            case .idle:
                placeholder
            case .loading:
                ProgressView("Loading…").foregroundColor(.white)
            case .ready, .playing, .paused, .seeking, .ended:
                if session.isAudioOnly {
                    AudioOnlyView()
                } else if let renderer = session.renderer as? MetalRenderer {
                    MetalMtkView(renderer: renderer)
                } else {
                    placeholder
                }
            case .error:
                Text(session.lastErrorMessage ?? "Playback error")
                    .foregroundColor(.red)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            Text("Drop a video file here").foregroundColor(.gray)
            Text("or use File > Open").font(.caption).foregroundColor(.gray)
        }
    }
}

struct SubtitleOverlay: View {
    let events: [SubtitleEvent]
    let hasMetalBitmap: Bool

    var body: some View {
        if hasMetalBitmap {
            EmptyView()
        } else {
            VStack {
                Spacer()
                ForEach(events, id: \.startTime) { event in
                    Text(event.text)
                        .font(.system(size: event.style.fontSize))
                        .foregroundColor(Color(
                            red: event.style.foregroundColor.r,
                            green: event.style.foregroundColor.g,
                            blue: event.style.foregroundColor.b))
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 60)
                }
            }
        }
    }
}
