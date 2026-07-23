import Foundation

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var items: [MediaItem.ID]
    var artworkURL: URL?
    let dateCreated: Date
    var dateModified: Date
    var isSmart: Bool
    var smartRules: [SmartPlaylistRule]?
    var sortOrder: PlaylistSort

    var totalDuration: TimeInterval {
        0
    }

    init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        items: [MediaItem.ID] = [],
        artworkURL: URL? = nil,
        dateCreated: Date = Date(),
        dateModified: Date = Date(),
        isSmart: Bool = false,
        smartRules: [SmartPlaylistRule]? = nil,
        sortOrder: PlaylistSort = .custom
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.items = items
        self.artworkURL = artworkURL
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.isSmart = isSmart
        self.smartRules = smartRules
        self.sortOrder = sortOrder
    }

    mutating func add(_ id: MediaItem.ID) {
        guard !items.contains(id) else { return }
        items.append(id)
        dateModified = Date()
    }

    mutating func remove(_ id: MediaItem.ID) {
        items.removeAll { $0 == id }
        dateModified = Date()
    }

    mutating func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        dateModified = Date()
    }
}

enum PlaylistSort: String, Codable, Sendable {
    case title
    case dateAdded
    case duration
    case custom
}

struct SmartPlaylistRule: Codable, Sendable {
    var field: String
    var op: String
    var value: String
}
