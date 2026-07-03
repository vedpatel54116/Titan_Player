import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine
import os

struct PlayerView: View {
    @EnvironmentObject var session: PlaybackSession
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "PlayerView")
    @State private var showControls = true
    @State private var cursorHidden = false
    @State private var showingFileImporter = false
    @State private var lastInteraction = Date.distantFuture
    @State private var autoHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Cmd-click overlay for the frame-accurate color picker.
            // Sits beneath subtitle/control layers so it captures view clicks
            // without interfering with subtitle hit-testing or the control bar.
            if let analysis = session.analysis {
                ColorPickerOverlay(
                    manager: analysis,
                    viewSizeProvider: { .zero },
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

            if session.isCompatibilityMode {
                VStack {
                    HStack {
                        Text("Compatibility Mode")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)
            }

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
        .accessibilityLabel("Video Player")
        .accessibilityHint("Double-tap to show controls")
        .onAppear { revealControls() }
        .onHover { hovering in
            if hovering { revealControls() }
        }
        .onChange(of: showControls) { _, visible in
            if visible { unhideCursor() } else if session.playState == .playing { hideCursor() }
        }
        .onChange(of: session.playState) { _, newstate in
            if newstate == .playing {
                revealControls()
            } else {
                autoHideTask?.cancel()
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
        lastInteraction = Date()
        withAnimation { showControls = true }
        if cursorHidden { unhideCursor() }
        autoHideTask?.cancel()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            guard session.playState == .playing else { return }
            let elapsed = Date().timeIntervalSince(lastInteraction)
            guard elapsed >= 3 else { scheduleAutoHide(); return }
            withAnimation { showControls = false }
            hideCursor()
        }
    }

    private func hideCursor() { cursorHidden = true; NSCursor.hide() }
    private func unhideCursor() { if cursorHidden { cursorHidden = false; NSCursor.unhide() } }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        revealControls()
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            logger.info("File dropped: \(url.path, privacy: .public)")
            Task { @MainActor in await session.openFile(url: url) }
        }
        return true
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            logger.info("File selected via picker: \(url.path, privacy: .public)")
            Task { @MainActor in await session.openFile(url: url) }
        case .failure(let error):
            logger.error("File picker error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct VideoContentView: View {
    @EnvironmentObject var session: PlaybackSession
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "PlayerView")
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
                logger.info("File selected: \(url.path, privacy: .public)")
                Task { @MainActor in await session.openFile(url: url) }
            case .failure(let error):
                logger.error("File picker error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 64))
                .foregroundColor(.gray)
                .accessibilityHidden(true)
            Text("Drop a file here to play").foregroundColor(.gray)
            Text("or use File > Open").font(.caption).foregroundColor(.gray)
            Button("Open File…") {
                showingFileImporter = true
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 8)
            .accessibilityLabel("Open file")
            .accessibilityHint("Opens a file picker to choose a media file")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No file loaded. Tap to open a file.")
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
                        .accessibilityLabel("Subtitle: \(event.text)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(events.first.map { "Subtitle: \($0.text)" } ?? "No subtitles")
        }
    }
}
