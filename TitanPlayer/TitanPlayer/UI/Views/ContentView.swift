//
//  ContentView.swift
//  TitanPlayer
//
//  Main player view with video rendering, controls, library sidebar,
//  file importer, drag & drop, and URL handling.
//

import SwiftUI
import AVKit
import UniformTypeIdentifiers
import os.log

struct ContentView: View {
    @EnvironmentObject var session: PlaybackSession
    @EnvironmentObject var telemetry: TelemetryManager
    @EnvironmentObject var library: LibraryStore

    @State private var isFileImporterPresented = false
    @State private var isDragging = false
    @State private var showLibrary = false
    @State private var showInspector = false
    @State private var showAnalysis = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let logger = Logger(subsystem: "com.titanplayer.app", category: "ContentView")

    // MARK: - Supported File Types

    /// All UTTypes the file importer should allow.
    private var allowedContentTypes: [UTType] {
        var types: [UTType] = [
            .movie,
            .video,
            .audio,
            .audiovisualContent,
            .mpeg4Movie,
            .quickTimeMovie,
            .mpeg,
            .avi,
        ]

        // Add format-specific UTTypes where available
        let customUTIs = [
            "org.matroska.mkv",
            "org.webmproject.webm",
            "com.microsoft.advanced-systems-format",
            "com.real.realmedia",
            "org.videolan.vlc",
            "public.mpeg-2-video",
            "public.mpeg-4",
            "com.apple.m4v-video",
            "public.3gpp",
            "public.3gpp2",
            "org.ogg.theora",
            "com.divx.divx",
        ]

        for uti in customUTIs {
            if let type = UTType(uti) {
                types.append(type)
            }
        }

        return types
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            if showLibrary {
                LibrarySidebar()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
            }
        } detail: {
            ZStack {
                // ── Video / Audio Rendering ──
                videoLayer

                // ── Drag & Drop Overlay ──
                if isDragging {
                    dropOverlay
                }

                // ── Empty State ──
                if !session.isMediaLoaded && !session.isLoading {
                    emptyStateView
                }

                // ── Loading Indicator ──
                if session.isLoading {
                    loadingOverlay
                }

                // ── Controls ──
                VStack {
                    Spacer()
                    if session.isMediaLoaded {
                        ControlBar()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        // ── File Importer ──
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImporterResult(result)
        }
        // ── Drag & Drop ──
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
        // ── CRITICAL: Handle files opened from Finder ──
        .onOpenURL { url in
            logger.info("ContentView: onOpenURL: \(url.absoluteString)")
            handleIncomingURL(url)
        }
        // ── Toolbar ──
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarButtons
            }
        }
        // ── Keyboard Shortcuts ──
        .background(ShortcutHandler(session: session))
        // ── Error Alert ──
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        // ── Window Configuration ──
        .configureWindow { window in
            window.titleVisibility = session.isMediaLoaded ? .visible : .hidden
            window.title = session.currentTitle ?? "Titan Player"
        }
    }

    // MARK: - Video Layer

    @ViewBuilder
    private var videoLayer: some View {
        if session.isAudioOnly {
            AudioOnlyView(compact: false)
        } else if session.isCompatibilityMode {
            AVPlayerViewWrapper(player: session.avPlayer)
                .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
        } else if session.isMediaLoaded {
            MirrorMTKView(frameStore: session.frameStore)
                .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
        } else {
            Color.black
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No Media Loaded")
                .font(.title2)
                .fontWeight(.medium)

            Text("Drag & drop a video file here, or click Open to browse.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(action: { isFileImporterPresented = true }) {
                    Label("Open File", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: { showLibrary.toggle() }) {
                    Label("Library", systemImage: "books.vertical")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Recent files from library
            if !library.recentItems.isEmpty {
                Divider()
                    .frame(width: 300)

                Text("Recent")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(library.recentItems.prefix(5)) { item in
                    Button(action: { openFile(at: item.url) }) {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(.secondary)
                            Text(item.url.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Loading…")
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Drop Overlay

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.15)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("Drop to Play")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbarButtons: some View {
        Button(action: { isFileImporterPresented = true }) {
            Label("Open", systemImage: "folder")
        }
        .help("Open a media file (⌘O)")

        Button(action: { showLibrary.toggle() }) {
            Label("Library", systemImage: "books.vertical")
        }
        .help("Toggle Library sidebar")

        Button(action: { showInspector.toggle() }) {
            Label("Inspector", systemImage: "info.circle")
        }
        .help("Toggle Media Inspector (⌘I)")

        Button(action: { showAnalysis.toggle() }) {
            Label("Analysis", systemImage: "waveform")
        }
        .help("Toggle Video Analysis")

        Divider()

        Button(action: { session.toggleMiniPlayer() }) {
            Label("Mini Player", systemImage: "pip")
        }
        .help("Toggle Mini Player")
    }

    // MARK: - File Handling

    /// Handle the result of the fileImporter dialog.
    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            logger.info("ContentView: FileImporter selected \(urls.count) file(s)")

            // Open the first file, add rest to library
            openFile(at: urls[0])
            if urls.count > 1 {
                library.addItems(Array(urls.dropFirst()))
            }

        case .failure(let error):
            logger.error("ContentView: FileImporter error: \(error)")
            showErrorMessage("File selection failed: \(error.localizedDescription)")
        }
    }

    /// Handle drag & drop.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            // Use modern UTType identifier instead of deprecated kUTTypeFileURL
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let error = error {
                        logger.error("ContentView: Drop load error: \(error)")
                        return
                    }

                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        logger.error("ContentView: Drop: could not parse file URL")
                        return
                    }

                    DispatchQueue.main.async {
                        openFile(at: url)
                    }
                }
            }
            // Also handle plain URLs (e.g., from browsers)
            else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                    DispatchQueue.main.async {
                        handleIncomingURL(url)
                    }
                }
            }
        }

        return handled
    }

    /// Handle an incoming URL from any source (Finder, drag & drop, URL scheme).
    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            openFile(at: url)
        } else if url.scheme == "http" || url.scheme == "https" {
            openStreamingURL(url)
        } else if url.scheme == "titanplayer" {
            // Parse titanplayer://open?path=...
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
                openFile(at: URL(fileURLWithPath: path))
            }
        }
    }

    /// Open a local media file.
    private func openFile(at url: URL) {
        // Validate the file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            showErrorMessage("File not found: \(url.lastPathComponent)")
            return
        }

        // Validate it's a supported format
        guard isSupportedMediaFile(url) else {
            showErrorMessage("Unsupported format: .\(url.pathExtension)")
            return
        }

        // Check if already playing this file
        if session.currentFileURL == url {
            logger.info("ContentView: File already open, skipping: \(url.lastPathComponent)")
            return
        }

        logger.info("ContentView: Opening file: \(url.lastPathComponent)")

        Task { @MainActor in
            do {
                try await session.openFile(url: url)
                library.addToRecent(url)
            } catch {
                logger.error("ContentView: Failed to open file: \(error)")
                showErrorMessage("Cannot open \"\(url.lastPathComponent)\": \(error.localizedDescription)")
            }
        }
    }

    /// Open a streaming URL.
    private func openStreamingURL(_ url: URL) {
        logger.info("ContentView: Opening stream: \(url.absoluteString)")

        Task { @MainActor in
            do {
                try await session.openStreamingURL(url)
            } catch {
                showErrorMessage("Cannot open stream: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Validation

    private func isSupportedMediaFile(_ url: URL) -> Bool {
        let supportedExtensions: Set<String> = [
            "mp4", "m4v", "mov", "mkv", "webm", "flv", "ts", "mts", "m2ts",
            "avi", "wmv", "mpg", "mpeg", "3gp", "3g2", "ogv", "vob",
            "rm", "rmvb", "asf", "divx", "f4v", "hevc", "mxf",
            "mp3", "aac", "flac", "wav", "aiff", "aif", "m4a", "ogg",
            "opus", "wma", "ac3", "eac3", "dts", "alac", "ape", "mpc",
            "m3u", "m3u8", "pls"
        ]
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Error Display

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(PlaybackSession())
        .environmentObject(TelemetryManager.shared)
        .environmentObject(LibraryStore.shared)
}
