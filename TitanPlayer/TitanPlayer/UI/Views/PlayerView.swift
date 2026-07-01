import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PlayerView: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var showControls = true
    @State private var hideWorkItem: DispatchWorkItem?
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

            SubtitleOverlay(events: session.currentSubtitleEvents)

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
        hideWorkItem?.cancel()
        if cursorHidden { unhideCursor() }
        if session.playState == .playing {
            let work = DispatchWorkItem {
                if session.playState == .playing {
                    withAnimation { showControls = false }
                }
            }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func startHideTimer() { revealControls() }
    private func cancelHideTimer() { hideWorkItem?.cancel(); hideWorkItem = nil }

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

    var body: some View {
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
