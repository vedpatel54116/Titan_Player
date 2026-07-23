import Foundation

struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let securityBookmark: Data?
    let title: String
    let displayTitle: String
    let fileSize: UInt64
    let duration: TimeInterval
    let dateAdded: Date
    let dateModified: Date
    let lastPlayed: Date?
    let playCount: Int
    let lastPosition: TimeInterval
    let isFavorite: Bool
    let thumbnailPath: String?
    let codecInfo: VideoCodecInfo?
    let audioInfo: AudioTrackSummary?
    let resolution: CGSize?
    let bitrate: Int?
    let isHDR: Bool
    let metadata: [String: String]

    var fileExtension: String {
        url.pathExtension
    }

    var isVideo: Bool {
        SupportedMediaTypes.videoExtensions.contains(fileExtension.lowercased())
    }

    static func makePlaceholder(url: URL) -> MediaItem {
        MediaItem(
            id: UUID(),
            url: url,
            securityBookmark: nil,
            title: url.deletingPathExtension().lastPathComponent,
            displayTitle: url.deletingPathExtension().lastPathComponent,
            fileSize: 0,
            duration: 0,
            dateAdded: Date(),
            dateModified: Date(),
            lastPlayed: nil,
            playCount: 0,
            lastPosition: 0,
            isFavorite: false,
            thumbnailPath: nil,
            codecInfo: nil,
            audioInfo: nil,
            resolution: nil,
            bitrate: nil,
            isHDR: false,
            metadata: [:]
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
}
