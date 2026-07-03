import Foundation
import os

final class SandboxBookmarkManager {
    static let shared = SandboxBookmarkManager()

    private let defaults = UserDefaults.standard
    private let bookmarkKeyPrefix = "sandbox_bookmark_"

    private init() {}

    func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let key = bookmarkKey(for: url)
            defaults.set(bookmarkData, forKey: key)
        } catch {
            os.Logger(subsystem: "com.titanplayer", category: "SandboxBookmark").error("Failed to create bookmark: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resolveBookmark(for url: URL) -> URL? {
        let key = bookmarkKey(for: url)
        guard let bookmarkData = defaults.data(forKey: key) else { return nil }

        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                saveBookmark(for: url)
            }

            return resolvedURL
        } catch {
            os.Logger(subsystem: "com.titanplayer", category: "SandboxBookmark").error("Failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func bookmarkKey(for url: URL) -> String {
        bookmarkKeyPrefix + url.path.replacingOccurrences(of: "/", with: "_")
    }
}
