import Foundation
import UniformTypeIdentifiers

/// Single source of truth for all media extensions Titan Player can open.
/// The engine (MediaPipeline) routes to AVFoundation or FFmpeg based on these.
enum SupportedMediaTypes {

    // MARK: - Video extensions ( recognised by the engine's backend router )

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov",           // AVFoundation direct
        "mkv", "webm", "avi", "wmv",   // FFmpeg preferred
        "flv", "ts", "ogv", "3gp", "rm",
    ]

    // MARK: - Audio extensions

    static let audioExtensions: Set<String> = [
        "mp3", "wav", "aiff", "flac", "m4a", "ogg", "wma",
    ]

    // MARK: - Playlist / streaming

    static let playlistExtensions: Set<String> = [
        "m3u8",
    ]

    // MARK: - All playable extensions (video + audio + playlist)

    static let allExtensions: Set<String> = videoExtensions
        .union(audioExtensions)
        .union(playlistExtensions)

    // MARK: - UTType list for SwiftUI .fileImporter / NSOpenPanel

    /// Comprehensive UTType array for file picker dialogs.
    static let filePickerTypes: [UTType] = [
        // System-defined types covering most containers
        .movie, .video, .mpeg4Movie, .quickTimeMovie,
        .avi, .mpeg2Video,
        .audio, .mp3, .wav, .aiff,
        // Types without a system UTI — construct from extension
        UTType(filenameExtension: "mkv")  ?? .data,
        UTType(filenameExtension: "webm") ?? .data,
        UTType(filenameExtension: "flv")  ?? .data,
        UTType(filenameExtension: "ts")   ?? .data,
        UTType(filenameExtension: "ogv")  ?? .data,
        UTType(filenameExtension: "3gp")  ?? .data,
        UTType(filenameExtension: "rm")   ?? .data,
        UTType(filenameExtension: "wmv")  ?? .data,
        UTType(filenameExtension: "m4v")  ?? .data,
        UTType(filenameExtension: "flac") ?? .data,
        UTType(filenameExtension: "m4a")  ?? .data,
        UTType(filenameExtension: "ogg")  ?? .data,
        UTType(filenameExtension: "m3u8") ?? .data,
    ]

    /// Returns `true` when the file extension is one the engine can handle.
    static func isSupported(_ url: URL) -> Bool {
        allExtensions.contains(url.pathExtension.lowercased())
    }

    /// Returns `true` for video file extensions specifically.
    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}
