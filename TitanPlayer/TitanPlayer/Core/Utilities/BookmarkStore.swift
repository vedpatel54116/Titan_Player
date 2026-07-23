//
//  BookmarkStore.swift
//  TitanPlayer
//
//  Persists security-scoped bookmarks so files can be reopened
//  across app launches without requiring the user to re-select them.
//

import Foundation
import os.log

struct BookmarkStore {
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "BookmarkStore")

    /// Directory where bookmark files are stored.
    private var bookmarksDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("TitanPlayer/Bookmarks", isDirectory: true)

        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir
    }

    // MARK: - Save

    /// Save a security-scoped bookmark for a file URL.
    mutating func save(bookmark data: Data, for url: URL) {
        let fileName = bookmarkFileName(for: url)
        let fileURL = bookmarksDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL, options: .atomic)
            logger.info("BookmarkStore: Saved bookmark for \(url.lastPathComponent)")
        } catch {
            logger.error("BookmarkStore: Failed to save bookmark: \(error)")
        }
    }

    // MARK: - Load

    /// Load a bookmark for a file URL.
    func loadBookmark(for url: URL) -> Data? {
        let fileName = bookmarkFileName(for: url)
        let fileURL = bookmarksDirectory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            logger.info("BookmarkStore: Loaded bookmark for \(url.lastPathComponent)")
            return data
        } catch {
            logger.error("BookmarkStore: Failed to load bookmark: \(error)")
            return nil
        }
    }

    /// Resolve a bookmark to a URL.
    func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false

        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.warning("BookmarkStore: Bookmark is stale for \(url.lastPathComponent)")
                // Recreate the bookmark
                if let newData = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    var mutableSelf = self
                    mutableSelf.save(bookmark: newData, for: url)
                }
            }

            return url
        } catch {
            logger.error("BookmarkStore: Failed to resolve bookmark: \(error)")
            return nil
        }
    }

    // MARK: - Delete

    /// Remove a bookmark for a file URL.
    mutating func removeBookmark(for url: URL) {
        let fileName = bookmarkFileName(for: url)
        let fileURL = bookmarksDirectory.appendingPathComponent(fileName)

        try? FileManager.default.removeItem(at: fileURL)
        logger.info("BookmarkStore: Removed bookmark for \(url.lastPathComponent)")
    }

    /// Remove all bookmarks.
    mutating func removeAll() {
        try? FileManager.default.removeItem(at: bookmarksDirectory)
        logger.info("BookmarkStore: Removed all bookmarks")
    }

    // MARK: - List

    /// List all saved bookmark URLs.
    func allBookmarkedURLs() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: bookmarksDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return contents.compactMap { fileURL -> URL? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return resolveBookmark(data)
        }
    }

    // MARK: - Helpers

    /// Generate a deterministic file name for a bookmark based on the URL.
    private func bookmarkFileName(for url: URL) -> String {
        // Use a hash of the absolute path to avoid filesystem-unsafe characters
        let path = url.absoluteString
        let hash = path.utf8.reduce(into: UInt64(0x9E3779B97F4A7C15)) { result, byte in
            result ^= UInt64(byte) &+ 0x9E3779B97F4A7C15 &+ (result << 6) &+ (result >> 2)
        }
        return String(format: "%016llX.bookmark", hash)
    }
}
