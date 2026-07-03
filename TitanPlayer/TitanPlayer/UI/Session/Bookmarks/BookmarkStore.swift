import Foundation
import os

@MainActor
final class BookmarkStore {
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "BookmarkManager")
    private let defaultsKey = "SecurityScopedBookmarks"

    private(set) var currentlyAccessedURL: URL?

    func createBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func resolveBookmark(for path: String) -> URL? {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data],
              let bookmarkData = bookmarks[path] else {
            return nil
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.warning("Stale bookmark detected for path: \(path, privacy: .public)")
                removeBookmark(for: path)
                return nil
            }

            return url
        } catch {
            logger.error("Failed to resolve bookmark for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            removeBookmark(for: path)
            return nil
        }
    }

    func removeBookmark(for path: String) {
        var bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: path)
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
        logger.info("Removed stale bookmark for path: \(path, privacy: .public)")
    }

    func startAccessing(url: URL) -> URL {
        var accessURL = url
        if let resolvedURL = resolveBookmark(for: url.path) {
            logger.info("Bookmark resolved successfully for: \(resolvedURL.path, privacy: .public)")
            accessURL = resolvedURL
        } else {
            logger.warning("Failed to resolve bookmark for: \(url.path, privacy: .public), falling back to original URL")
        }

        let accessing = accessURL.startAccessingSecurityScopedResource()
        if !accessing {
            logger.warning("startAccessingSecurityScopedResource() returned false for: \(accessURL.path, privacy: .public). Proceeding with file access attempt.")
        } else {
            logger.info("Security-scoped access started successfully for: \(accessURL.path, privacy: .public)")
        }

        currentlyAccessedURL = accessURL
        return accessURL
    }

    func stopAccessingCurrentResource() {
        if let currentURL = currentlyAccessedURL {
            currentURL.stopAccessingSecurityScopedResource()
            logger.info("Stopped accessing: \(currentURL.path, privacy: .public)")
            currentlyAccessedURL = nil
        }
    }
}
