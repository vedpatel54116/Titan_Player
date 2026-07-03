import SwiftUI
import UniformTypeIdentifiers
import os

struct ContentView: View {
    @EnvironmentObject private var session: PlaybackSession
    @StateObject private var libraryViewModel = LibraryViewModel()
    @State private var showingFileImporter = false
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "PlayerView")

    private let supportedContentTypes: [UTType] = [
        .movie, .video, .mpeg4Movie, .quickTimeMovie,
        .avi, .mpeg2Video,
        .audio, .mp3, .wav, .aiff,
        UTType(filenameExtension: "m3u8") ?? .data,
        UTType(filenameExtension: "mkv") ?? .data,
        UTType(filenameExtension: "webm") ?? .data,
        UTType(filenameExtension: "flac") ?? .data,
    ]

    var body: some View {
        HSplitView {
            SidebarView(viewModel: libraryViewModel)
                .frame(minWidth: 200, idealWidth: 250)

            PlayerView()
                .frame(minWidth: 640, minHeight: 480)
        }
        .frame(minWidth: 800, minHeight: 450)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImporterResult(result)
        }
        .alert("File Open Error", isPresented: .init(
            get: { session.fileOpenError != nil },
            set: { if !$0 { session.dismissFileOpenError() } }
        )) {
            Button("OK") { session.dismissFileOpenError() }
        } message: {
            Text(session.fileOpenError ?? "")
        }
        .alert("Playback Error", isPresented: .init(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.dismissErrorMessage() } }
        )) {
            Button("OK") { session.dismissErrorMessage() }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
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
