import SwiftUI

struct LibraryWindowView: View {
    let rootFolder: URL?
    @StateObject private var libraryViewModel = LibraryViewModel()
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(rootFolder?.lastPathComponent ?? "Library")
                    .font(.headline)
                Spacer()
                Button(action: { openFolder() }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
            }
            .padding()

            if libraryViewModel.mediaFiles.isEmpty {
                Text("No media files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(libraryViewModel.mediaFiles) { item in
                    Button(action: { Task { await session.openFile(url: item.url) } }) {
                        HStack {
                            Image(systemName: "film")
                                .foregroundColor(.accentColor)
                            Text(item.title).lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 400)
        .onAppear {
            if let url = rootFolder {
                libraryViewModel.loadFolder(url: url)
            }
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                libraryViewModel.loadFolder(url: url)
            }
        }
    }
}
