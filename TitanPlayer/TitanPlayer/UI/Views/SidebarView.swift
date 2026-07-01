import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject var session: PlaybackSession
    @State private var selectedSection: SidebarSection = .library

    enum SidebarSection: String, CaseIterable {
        case library = "Library"
        case playlists = "Playlists"
        case recent = "Recent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Section", selection: $selectedSection) {
                ForEach(SidebarSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch selectedSection {
            case .library:
                LibrarySection(viewModel: viewModel)
            case .playlists:
                PlaylistsSection(viewModel: viewModel)
            case .recent:
                RecentSection(viewModel: viewModel)
            }

            Spacer()
        }
    }
}

struct LibrarySection: View {
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Media Files").font(.headline)
                Spacer()
                Button(action: { openFolder() }) { Image(systemName: "folder") }
                    .buttonStyle(.plain)
            }

            if viewModel.mediaFiles.isEmpty {
                Text("No media files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.mediaFiles) { item in
                    MediaItemRow(item: item)
                }
                .listStyle(.plain)
            }
        }
        .padding()
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.loadFolder(url: url)
            }
        }
    }
}

struct MediaItemRow: View {
    let item: MediaItem
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        Button(action: { Task { await session.openFile(url: item.url) } }) {
            HStack {
                Image(systemName: "film").foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text(item.title).lineLimit(1)
                    Text(formatDate(item.dateAdded))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        return f.string(from: date)
    }
}

struct PlaylistsSection: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playlists").font(.headline)
                Spacer()
                Button(action: { viewModel.createPlaylist(name: "New Playlist") }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            if viewModel.playlists.isEmpty {
                Text("No playlists")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.playlists) { playlist in Text(playlist.name) }
                    .listStyle(.plain)
            }
        }
        .padding()
    }
}

struct RecentSection: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played").font(.headline)
            if viewModel.recentlyPlayed.isEmpty {
                Text("No recent files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.recentlyPlayed) { item in MediaItemRow(item: item) }
                    .listStyle(.plain)
            }
        }
        .padding()
    }
}
