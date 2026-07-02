import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PlayerView: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var showControls = true
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var cursorHidden = false
    @State private var showingFileImporter = false

    var body: some View {
        ZStack {
            // Cmd-click overlay for the frame-accurate color picker.
            // Sits beneath subtitle/control layers so it captures view clicks
            // without interfering with subtitle hit-testing or the control bar.
            if let analysis = session.analysis {
                ColorPickerOverlay(
                    manager: analysis,
                    viewSizeProvider: { .zero },  // unused; we resolve from GeometryReader
                    sourceSizeProvider: { analysis.latestTextureSize },
                    fitMode: session.effectiveFitMode
                ) {
                    VideoContentView()
                        .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
                        .onTapGesture { revealControls() }
                }
            } else {
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
        .onChange(of: showControls) { _, visible in
            if visible { unhideCursor() } else if session.playState == .playing { hideCursor() }
        }
        .onChange(of: session.playState) { _, newstate in
            if newstate == .playing {
                revealControls()
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
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [
                .movie, .video, .mpeg4Movie, .quickTimeMovie,
                .avi, .mpeg2Video,
                .audio, .mp3, .wav, .aiff,
                UTType(filenameExtension: "m3u8") ?? .data,
                UTType(filenameExtension: "mkv") ?? .data,
                UTType(filenameExtension: "webm") ?? .data,
                UTType(filenameExtension: "flac") ?? .data,
            ],
            allowsMultipleSelection: false
        ) { result in
            handleFileImporterResult(result)
        }
    }

    private func revealControls() {
        hideWorkItem?.cancel()
        withAnimation { showControls = true }
        if cursorHidden { unhideCursor() }
        guard session.playState == .playing else { return }
        let work = DispatchWorkItem { [self] in
            guard session.playState == .playing else { return }
            withAnimation { showControls = false }
            hideCursor()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func cancelHideTimer() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func hideCursor() { cursorHidden = true; NSCursor.hide() }
    private func unhideCursor() { if cursorHidden { cursorHidden = false; NSCursor.unhide() } }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            NSLog("[PlayerView] File dropped: %@", url.path)
            Task { @MainActor in await session.openFile(url: url) }
        }
        return true
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            NSLog("[PlayerView] File selected via picker: %@", url.path)
            Task { @MainActor in await session.openFile(url: url) }
        case .failure(let error):
            NSLog("[PlayerView] File picker error: %@", error.localizedDescription)
        }
    }
}

struct VideoContentView: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var showingFileImporter = false

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
                } else if session.isCompatibilityMode {
                    AVPlayerViewWrapper(player: session.avPlayer)
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
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [
                .movie, .video, .mpeg4Movie, .quickTimeMovie,
                .avi, .mpeg2Video,
                .audio, .mp3, .wav, .aiff,
                UTType(filenameExtension: "m3u8") ?? .data,
                UTType(filenameExtension: "mkv") ?? .data,
                UTType(filenameExtension: "webm") ?? .data,
                UTType(filenameExtension: "flac") ?? .data,
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                NSLog("[VideoContentView] File selected: %@", url.path)
                Task { @MainActor in await session.openFile(url: url) }
            case .failure(let error):
                NSLog("[VideoContentView] File picker error: %@", error.localizedDescription)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            Text("Drop a file here to play").foregroundColor(.gray)
            Text("or use File > Open").font(.caption).foregroundColor(.gray)
            Button("Open File…") {
                showingFileImporter = true
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 8)
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
