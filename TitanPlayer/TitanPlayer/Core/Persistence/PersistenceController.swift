import Foundation
import SwiftData
import os

// MARK: - SwiftData model objects

/// SwiftData-backed persistence for a `MediaItem`.
///
/// `MediaItem` itself is a value-type `struct` used throughout the app, so we
/// keep it as the public API and mirror it here as an `@Model` reference type.
/// Nested value types (`VideoCodecInfo`, `AudioTrackSummary`, `CGSize`, the
/// `[String: String]` metadata dictionary) are stored as encoded `Data` because
/// SwiftData only natively persists a fixed set of attribute types; the id is
/// `@Attribute(.unique)` so saves become upserts.
@Model
final class PersistedMediaItem {
    @Attribute(.unique) var id: UUID
    var urlPath: String
    var securityBookmark: Data?
    var title: String
    var displayTitle: String
    var fileSize: UInt64
    var duration: TimeInterval
    var dateAdded: Date
    var dateModified: Date
    var lastPlayed: Date?
    var playCount: Int
    var lastPosition: TimeInterval
    var isFavorite: Bool
    var thumbnailPath: String?
    var bitrate: Int?
    var isHDR: Bool

    // Flattened / encoded nested value types.
    var resolutionWidth: Double?
    var resolutionHeight: Double?
    var codecInfoData: Data?
    var audioInfoData: Data?
    var metadataData: Data?

    /// Convenience initializer for the migration path: builds a placeholder item
    /// for `url` already carrying a security-scoped `bookmark`.
    convenience init(url: URL, securityBookmark: Data?) {
        self.init(from: MediaItem.makePlaceholder(url: url))
        self.securityBookmark = securityBookmark
    }

    init(from item: MediaItem) {
        self.id = item.id
        self.urlPath = item.url.path
        self.securityBookmark = item.securityBookmark
        self.title = item.title
        self.displayTitle = item.displayTitle
        self.fileSize = item.fileSize
        self.duration = item.duration
        self.dateAdded = item.dateAdded
        self.dateModified = item.dateModified
        self.lastPlayed = item.lastPlayed
        self.playCount = item.playCount
        self.lastPosition = item.lastPosition
        self.isFavorite = item.isFavorite
        self.thumbnailPath = item.thumbnailPath
        self.bitrate = item.bitrate
        self.isHDR = item.isHDR

        if let resolution = item.resolution {
            self.resolutionWidth = Double(resolution.width)
            self.resolutionHeight = Double(resolution.height)
        }
        self.codecInfoData = try? JSONEncoder().encode(item.codecInfo)
        self.audioInfoData = try? JSONEncoder().encode(item.audioInfo)
        self.metadataData = try? JSONEncoder().encode(item.metadata)
    }

    /// Updates every field from `item` in place (avoids re-inserting under the
    /// `@Attribute(.unique)` id constraint).
    func apply(_ item: MediaItem) {
        urlPath = item.url.path
        securityBookmark = item.securityBookmark
        title = item.title
        displayTitle = item.displayTitle
        fileSize = item.fileSize
        duration = item.duration
        dateAdded = item.dateAdded
        dateModified = item.dateModified
        lastPlayed = item.lastPlayed
        playCount = item.playCount
        lastPosition = item.lastPosition
        isFavorite = item.isFavorite
        thumbnailPath = item.thumbnailPath
        bitrate = item.bitrate
        isHDR = item.isHDR
        if let resolution = item.resolution {
            resolutionWidth = Double(resolution.width)
            resolutionHeight = Double(resolution.height)
        } else {
            resolutionWidth = nil
            resolutionHeight = nil
        }
        codecInfoData = try? JSONEncoder().encode(item.codecInfo)
        audioInfoData = try? JSONEncoder().encode(item.audioInfo)
        metadataData = try? JSONEncoder().encode(item.metadata)
    }

    func toMediaItem() -> MediaItem {        let resolution: CGSize?
        if let w = resolutionWidth, let h = resolutionHeight {
            resolution = CGSize(width: w, height: h)
        } else {
            resolution = nil
        }

        let codecInfo = (try? JSONDecoder().decode(VideoCodecInfo.self, from: codecInfoData ?? Data())) ?? nil
        let audioInfo = (try? JSONDecoder().decode(AudioTrackSummary.self, from: audioInfoData ?? Data())) ?? nil
        let metadata = (try? JSONDecoder().decode([String: String].self, from: metadataData ?? Data())) ?? [:]

        return MediaItem(
            id: id,
            url: URL(fileURLWithPath: urlPath),
            securityBookmark: securityBookmark,
            title: title,
            displayTitle: displayTitle,
            fileSize: fileSize,
            duration: duration,
            dateAdded: dateAdded,
            dateModified: dateModified,
            lastPlayed: lastPlayed,
            playCount: playCount,
            lastPosition: lastPosition,
            isFavorite: isFavorite,
            thumbnailPath: thumbnailPath,
            codecInfo: codecInfo,
            audioInfo: audioInfo,
            resolution: resolution,
            bitrate: bitrate,
            isHDR: isHDR,
            metadata: metadata
        )
    }
}

/// SwiftData-backed persistence for a `Playlist`.
///
/// `Playlist` references media by `MediaItem.ID` (`[UUID]`), so we persist the
/// id list directly rather than modelling a SwiftData relationship.
@Model
final class PersistedPlaylist {
    @Attribute(.unique) var id: UUID
    var name: String
    var playlistDescription: String
    var itemIDs: [UUID]
    var artworkURLPath: String?
    var dateCreated: Date
    var dateModified: Date
    var isSmart: Bool
    var smartRulesData: Data?
    var sortOrderRaw: String

    init(from playlist: Playlist) {
        self.id = playlist.id
        self.name = playlist.name
        self.playlistDescription = playlist.description
        self.itemIDs = playlist.items
        self.artworkURLPath = playlist.artworkURL?.path
        self.dateCreated = playlist.dateCreated
        self.dateModified = playlist.dateModified
        self.isSmart = playlist.isSmart
        self.smartRulesData = try? JSONEncoder().encode(playlist.smartRules)
        self.sortOrderRaw = playlist.sortOrder.rawValue
    }

    /// Updates every field from `playlist` in place.
    func apply(_ playlist: Playlist) {
        name = playlist.name
        playlistDescription = playlist.description
        itemIDs = playlist.items
        artworkURLPath = playlist.artworkURL?.path
        dateCreated = playlist.dateCreated
        dateModified = playlist.dateModified
        isSmart = playlist.isSmart
        smartRulesData = try? JSONEncoder().encode(playlist.smartRules)
        sortOrderRaw = playlist.sortOrder.rawValue
    }

    func toPlaylist() -> Playlist {
        let artworkURL: URL?
        if let path = artworkURLPath {
            artworkURL = URL(fileURLWithPath: path)
        } else {
            artworkURL = nil
        }
        let smartRules = (try? JSONDecoder().decode([SmartPlaylistRule].self, from: smartRulesData ?? Data())) ?? nil
        let sortOrder = PlaylistSort(rawValue: sortOrderRaw) ?? .custom

        return Playlist(
            id: id,
            name: name,
            description: playlistDescription,
            items: itemIDs,
            artworkURL: artworkURL,
            dateCreated: dateCreated,
            dateModified: dateModified,
            isSmart: isSmart,
            smartRules: smartRules,
            sortOrder: sortOrder
        )
    }
}

// MARK: - Migration

/// Keys previously used by `BookmarkStore` (see `Core/Utilities/BookmarkStore.swift`),
/// where security-scoped bookmarks were stored in `UserDefaults` as
/// `[String: Data]` keyed by the SHA-256 of the file path.
enum LegacyBookmarkStore {
    static let defaultsKey = "SecurityScopedBookmarks"
}

/// One-time migration of the legacy `UserDefaults` bookmark store into SwiftData.
///
/// The source of truth for security-scoped access used to live in
/// `BookmarkStore` (a `[pathHash: bookmarkData]` dictionary in
/// `UserDefaults.standard` under `LegacyBookmarkStore.defaultsKey`). This plan
/// moves that data into `PersistedMediaItem.securityBookmark`, keyed by the
/// canonical `MediaItem.id` rather than a path hash, so bookmarks survive file
/// renames/moves and dedupe correctly.
///
/// Migration strategy:
/// 1. Read `LegacyBookmarkStore.defaultsKey` from `UserDefaults.standard`.
/// 2. For every `(pathHash, bookmarkData)` entry, resolve the bookmark to a URL.
/// 3. Find (or create) the matching `PersistedMediaItem` by resolved path and
///    attach the `bookmarkData`; otherwise drop stale/unresolvable entries.
/// 4. Once all entries are migrated, remove `LegacyBookmarkStore.defaultsKey`
///    from `UserDefaults` so the migration runs exactly once.
struct BookmarkMigrationPlan {
    let logger = Logger(subsystem: "com.titanplayer.app", category: "Migration")

    /// Performs the one-time migration. Safe to call on every launch; it is a
    /// no-op once `LegacyBookmarkStore.defaultsKey` is absent.
    @MainActor
    func migrate(into controller: PersistenceController) {
        let raw = UserDefaults.standard.dictionary(forKey: LegacyBookmarkStore.defaultsKey) as? [String: Data]
        guard let entries = raw, !entries.isEmpty else {
            return
        }

        #if DEBUG
        logger.debug("Migrating \(entries.count) legacy bookmarks into SwiftData")
        #endif

        for (pathHash, bookmarkData) in entries {
            var isStale = false
            let url: URL
            do {
                url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                logger.warning("Dropping unresolvable legacy bookmark (hash \(pathHash)): \(error.localizedDescription)")
                continue
            }
            if isStale {
                logger.warning("Dropping stale legacy bookmark for \(url.path, privacy: .public)")
                continue
            }

            controller.attachBookmark(bookmarkData, forPath: url.path)
        }

        UserDefaults.standard.removeObject(forKey: LegacyBookmarkStore.defaultsKey)
        logger.info("Legacy bookmark migration complete")
    }
}

// MARK: - Persistence controller

/// Owns the SwiftData `ModelContainer` and exposes value-type (`MediaItem`,
/// `Playlist`) CRUD operations over the underlying `@Model` objects.
@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let modelContainer: ModelContainer
    let modelContext: ModelContext

    private let logger = Logger(subsystem: "com.titanplayer.app", category: "Persistence")

    /// - Parameter inMemory: when `true` the store is kept in memory only — used
    ///   by tests so they never touch disk or each other.
    init(inMemory: Bool = false) {
        let schema = Schema([PersistedMediaItem.self, PersistedPlaylist.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error.localizedDescription)")
        }
        modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = false
    }

    // MARK: - Media items

    /// Inserts or updates a `MediaItem` (match by `id`).
    func save(item: MediaItem) {
        if let existing = fetchPersisted(id: item.id) {
            existing.apply(item)
        } else {
            modelContext.insert(PersistedMediaItem(from: item))
        }
        persist()
    }

    /// Returns every persisted media item, sorted by `dateAdded` (newest last).
    func fetchAll() -> [MediaItem] {
        let descriptor = FetchDescriptor<PersistedMediaItem>(
            sortBy: [SortDescriptor(\.dateAdded, order: .forward)]
        )
        guard let results = try? modelContext.fetch(descriptor) else {
            logger.error("Failed to fetch media items")
            return []
        }
        return results.map { $0.toMediaItem() }
    }

    /// Fetches a single media item by id, or `nil` if not present.
    func fetch(id: MediaItem.ID) -> MediaItem? {
        fetchPersisted(id: id)?.toMediaItem()
    }

    /// Deletes the media item with the given id.
    func delete(id: MediaItem.ID) {
        guard let existing = fetchPersisted(id: id) else { return }
        modelContext.delete(existing)
        persist()
    }

    /// Internal helper: fetch the underlying `@Model` object by id (or `nil`).
    private func fetchPersisted(id: MediaItem.ID) -> PersistedMediaItem? {
        let predicate = #Predicate<PersistedMediaItem> { $0.id == id }
        let descriptor = FetchDescriptor<PersistedMediaItem>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    /// Internal helper used by the migration: attaches a legacy bookmark to the
    /// item matching `path`, creating a placeholder item if none exists yet.
    fileprivate func attachBookmark(_ bookmarkData: Data, forPath path: String) {
        let predicate = #Predicate<PersistedMediaItem> { $0.urlPath == path }
        let descriptor = FetchDescriptor<PersistedMediaItem>(predicate: predicate)
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.securityBookmark = bookmarkData
        } else {
            modelContext.insert(PersistedMediaItem(
                url: URL(fileURLWithPath: path),
                securityBookmark: bookmarkData
            ))
        }
        persist()
    }

    // MARK: - Playlists

    /// Inserts or updates a `Playlist` (match by `id`).
    func save(playlist: Playlist) {
        if let existing = fetchPersistedPlaylist(id: playlist.id) {
            existing.apply(playlist)
        } else {
            modelContext.insert(PersistedPlaylist(from: playlist))
        }
        persist()
    }

    /// Returns every persisted playlist.
    func fetchPlaylists() -> [Playlist] {
        let descriptor = FetchDescriptor<PersistedPlaylist>(
            sortBy: [SortDescriptor(\.dateModified, order: .reverse)]
        )
        guard let results = try? modelContext.fetch(descriptor) else {
            logger.error("Failed to fetch playlists")
            return []
        }
        return results.map { $0.toPlaylist() }
    }

    /// Fetches a single playlist by id, or `nil` if not present.
    func fetchPlaylist(id: Playlist.ID) -> Playlist? {
        fetchPersistedPlaylist(id: id)?.toPlaylist()
    }

    /// Deletes the playlist with the given id.
    func delete(playlistID: Playlist.ID) {
        guard let existing = fetchPersistedPlaylist(id: playlistID) else { return }
        modelContext.delete(existing)
        persist()
    }

    private func fetchPersistedPlaylist(id: Playlist.ID) -> PersistedPlaylist? {
        let predicate = #Predicate<PersistedPlaylist> { $0.id == id }
        let descriptor = FetchDescriptor<PersistedPlaylist>(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    // MARK: - Save helper

    /// Commits pending changes and logs (but does not throw on) failures so callers
    /// remain simple. `autosaveEnabled` is off, so this is the explicit flush point.
    private func persist() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Persistence save failed: \(error.localizedDescription)")
        }
    }
}
