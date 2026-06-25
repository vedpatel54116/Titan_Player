import SwiftUI
import Combine

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var mediaFiles: [MediaItem] = []
    @Published var playlists: [Playlist] = []
    @Published var recentlyPlayed: [MediaItem] = []
    @Published var selectedFolder: URL?
    
    private let supportedExtensions = ["mp4", "mkv", "mov", "avi", "wmv", "flac", "m4v"]
    
    func loadFolder(url: URL) {
        selectedFolder = url
        mediaFiles = scanFolder(url: url)
    }
    
    func scanFolder(url: URL) -> [MediaItem] {
        var items: [MediaItem] = []
        
        guard let enumerator = FileManager.default.enumerator(at: url,
                                                             includingPropertiesForKeys: [.isRegularFileKey],
                                                             options: [.skipsHiddenFiles]) else {
            return items
        }
        
        for case let fileURL as URL in enumerator {
            // Check if file has a supported extension
            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                let item = MediaItem(
                    id: fileURL,
                    url: fileURL,
                    title: fileURL.deletingPathExtension().lastPathComponent,
                    duration: 0,
                    dateAdded: Date()
                )
                items.append(item)
            }
        }
        
        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    
    func createPlaylist(name: String) {
        let playlist = Playlist(
            id: UUID(),
            name: name,
            items: [],
            dateCreated: Date()
        )
        playlists.append(playlist)
    }
    
    func addToPlaylist(_ playlist: Playlist, item: MediaItem) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].items.append(item)
    }
    
    func removeFromPlaylist(_ playlist: Playlist, item: MediaItem) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlist.id }),
              let itemIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        playlists[playlistIndex].items.remove(at: itemIndex)
    }
    
    func addToRecentlyPlayed(_ item: MediaItem) {
        recentlyPlayed.removeAll { $0.id == item.id }
        recentlyPlayed.insert(item, at: 0)
        if recentlyPlayed.count > 20 {
            recentlyPlayed = Array(recentlyPlayed.prefix(20))
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    let id: URL
    let url: URL
    let title: String
    let duration: Double
    let dateAdded: Date
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct Playlist: Identifiable {
    let id: UUID
    let name: String
    var items: [MediaItem]
    let dateCreated: Date
}
