import Foundation
import os

@MainActor
final class BookmarkStore {
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "FileOpen")

    private static let bookmarkDefaultsKey = "SecurityScopedBookmarks"

    private(set) var currentlyAccessedURL: URL?

    func createBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = UserDefaults.standard.dictionary(forKey: Self.bookmarkDefaultsKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: Self.bookmarkDefaultsKey)
        } catch {
            NSLog("[BookmarkManager] Failed to create bookmark for %@: %@", url.path, error.localizedDescription)
        }
    }

    func resolveBookmark(for path: String) -> URL? {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: Self.bookmarkDefaultsKey) as? [String: Data],
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
                NSLog("[BookmarkManager] Stale bookmark detected for path: %@", path)
                removeBookmark(for: path)
                return nil
            }

            return url
        } catch {
            NSLog("[BookmarkManager] Failed to resolve bookmark for %@: %@", path, error.localizedDescription)
            removeBookmark(for: path)
            return nil
        }
    }

    func removeBookmark(for path: String) {
        var bookmarks = UserDefaults.standard.dictionary(forKey: Self.bookmarkDefaultsKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: path)
        UserDefaults.standard.set(bookmarks, forKey: Self.bookmarkDefaultsKey)
        NSLog("[BookmarkManager] Removed stale bookmark for path: %@", path)
    }

    func startAccessing(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        if accessing {
            currentlyAccessedURL = url
            #if DEBUG
            logger.debug("Security-scoped access started successfully for: \(url.path, privacy: .public)")
            #endif
        }
        return accessing
    }

    func stopAccessing() {
        if let currentURL = currentlyAccessedURL {
            currentURL.stopAccessingSecurityScopedResource()
            NSLog("[BookmarkManager] Stopped accessing: %@", currentURL.path)
            currentlyAccessedURL = nil
        }
    }
}
