import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox
import os

/// Extracts display/playback metadata for a media file without fully decoding it.
///
/// Uses `AVURLAsset` to read container-level properties (playability, duration,
/// tracks, codecs, resolution, bitrate). Designed to be resilient: a failure to
/// read any single property reduces to a best-effort `MediaItem` rather than
/// throwing, so callers can always rely on getting back metadata. Results are
/// memoised in an `NSCache` keyed by the file URL.
actor MediaMetadataExtractor {
    private let logger = Logger(subsystem: "com.titanplayer", category: "MetadataExtractor")

    private let cache = NSCache<NSURL, ExtractedBox>()

    /// Builds a `MediaItem` of metadata for `url`.
    ///
    /// Security-scoped resource access (when the URL came from a sandboxed
    /// bookmark) is acquired for the whole read via `BookmarkStore`. The method
    /// is non-throwing by design for metadata-only extraction: if the asset
    /// cannot be opened or a property fails to load, a best-effort item is
    /// returned with `duration` set to `0`.
    func extractMetadata(for url: URL) async throws -> MediaItem {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.item
        }

        let bookmarkStore = await MainActor.run { BookmarkStore() }
        let item = await bookmarkStore.withSecurityScopedAccess(url: url) { scopedURL in
            await self.buildMetadata(for: scopedURL)
        }

        cache.setObject(ExtractedBox(item), forKey: url as NSURL)
        return item
    }

    // MARK: - Internal extraction

    private func buildMetadata(for url: URL) async -> MediaItem {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        let isPlayable = (try? await asset.load(.isPlayable)) ?? false

        let loadedDuration = try? await asset.load(.duration)
        let duration: TimeInterval = {
            guard let loaded = loadedDuration else { return 0 }
            let seconds = CMTimeGetSeconds(loaded)
            return seconds.isFinite ? seconds : 0
        }()

        let (fileSize, creationDate, modificationDate) = readFileAttributes(for: url)

        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        var resolution: CGSize?
        var bitrate: Int?
        var codecInfo: VideoCodecInfo?
        var isHDR = false

        if let videoTrack = videoTracks.first {
            if let size = try? await videoTrack.load(.naturalSize) {
                resolution = CGSize(width: size.width, height: size.height)
            }

            if let rate = try? await videoTrack.load(.estimatedDataRate), rate > 0 {
                bitrate = Int(rate)
            }

            if let description = (try? await videoTrack.load(.formatDescriptions))?.first {
                let codec = fourCharCodeToString(CMFormatDescriptionGetMediaSubType(description))
                let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
                isHDR = (extensions?["ContainsHDRMetadata"] as? Bool) ?? false
                codecInfo = VideoCodecInfo(codec: codec, profile: nil, bitDepth: nil, colorSpace: nil)
            }
        }

        var audioInfo: AudioTrackSummary?
        if let audioTrack = audioTracks.first,
           let description = (try? await audioTrack.load(.formatDescriptions))?.first {
            let codec = fourCharCodeToString(CMFormatDescriptionGetMediaSubType(description))
            var sampleRate = 0.0
            var channels = 0
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                sampleRate = asbd.mSampleRate
                channels = Int(asbd.mChannelsPerFrame)
            }
            let language = try? await audioTrack.load(.languageCode)
            audioInfo = AudioTrackSummary(
                codec: codec,
                channels: channels,
                sampleRate: sampleRate,
                language: language
            )
        }

        return MediaItem(
            id: UUID(),
            url: url,
            securityBookmark: nil,
            title: url.deletingPathExtension().lastPathComponent,
            displayTitle: url.deletingPathExtension().lastPathComponent,
            fileSize: fileSize,
            duration: duration,
            dateAdded: creationDate,
            dateModified: modificationDate,
            lastPlayed: nil,
            playCount: 0,
            lastPosition: 0,
            isFavorite: false,
            thumbnailPath: nil,
            codecInfo: codecInfo,
            audioInfo: audioInfo,
            resolution: resolution,
            bitrate: bitrate,
            isHDR: isHDR,
            metadata: ["isPlayable": "\(isPlayable)"]
        )
    }

    private func readFileAttributes(for url: URL) -> (size: UInt64, creation: Date, modification: Date) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (0, Date(), Date())
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let creation = (attrs[.creationDate] as? Date) ?? Date()
        let modification = (attrs[.modificationDate] as? Date) ?? Date()
        return (size, creation, modification)
    }

    private func fourCharCodeToString(_ code: OSType) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: code >> 24),
            UInt8(truncatingIfNeeded: code >> 16),
            UInt8(truncatingIfNeeded: code >> 8),
            UInt8(truncatingIfNeeded: code)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters).isEmpty == false
            ? String(bytes: bytes, encoding: .ascii)!
            : "unknown"
    }
}

/// Box used to store `MediaItem` values inside the `NSCache`, which requires
/// `NSObject` keys/values.
private final class ExtractedBox: NSObject {
    let item: MediaItem

    init(_ item: MediaItem) {
        self.item = item
        super.init()
    }
}
