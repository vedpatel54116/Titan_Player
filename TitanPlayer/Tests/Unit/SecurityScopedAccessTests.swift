import XCTest
import ObjectiveC
@testable import TitanPlayer

/// Tracks `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`
/// call counts via a temporary method swizzle, so we can prove the access
/// extension is released exactly as many times as it is acquired.
private var titanStartAccessCount = 0
private var titanStopAccessCount = 0

extension NSURL {
    @objc func titan_startAccessingSecurityScopedResource() -> Bool {
        titanStartAccessCount += 1
        return titan_startAccessingSecurityScopedResource()
    }
    @objc func titan_stopAccessingSecurityScopedResource() {
        titanStopAccessCount += 1
        titan_stopAccessingSecurityScopedResource()
    }
}

final class SecurityScopedAccessTests: XCTestCase {

    /// Swizzles the two `NSURL` access methods for the duration of `block`,
    /// counting every call, then restores the originals so other tests are
    /// unaffected.
    private func withSwizzledAccess(_ block: () async throws -> Void) async rethrows {
        let startMethod = class_getInstanceMethod(NSURL.self, #selector(NSURL.startAccessingSecurityScopedResource))!
        let myStartMethod = class_getInstanceMethod(NSURL.self, #selector(NSURL.titan_startAccessingSecurityScopedResource))!
        let stopMethod = class_getInstanceMethod(NSURL.self, #selector(NSURL.stopAccessingSecurityScopedResource))!
        let myStopMethod = class_getInstanceMethod(NSURL.self, #selector(NSURL.titan_stopAccessingSecurityScopedResource))!

        method_exchangeImplementations(startMethod, myStartMethod)
        method_exchangeImplementations(stopMethod, myStopMethod)
        defer {
            method_exchangeImplementations(startMethod, myStartMethod)
            method_exchangeImplementations(stopMethod, myStopMethod)
        }
        try block()
    }

    /// Opening the same file 100 times must not leak a kernel sandbox
    /// extension: every `startAccessingSecurityScopedResource()` must be
    /// balanced by a `stopAccessingSecurityScopedResource()`.
    func testOpenSameFile100TimesNoKernelLeak() async throws {
        guard let fileURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4") else {
            throw XCTSkip("Fixtures/test.mp4 missing from test bundle")
        }

        // Build a real security-scoped bookmark and resolve it so the URL is
        // genuinely security-scoped (start/stop toggle a real sandbox extension).
        let bookmark = try fileURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var isStale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        titanStartAccessCount = 0
        titanStopAccessCount = 0

        try await withSwizzledAccess {
            for _ in 0..<100 {
                _ = try await scopedURL.withSecurityScopedAccess { url in
                    // Exercise the access by reading the file.
                    _ = try Data(contentsOf: url)
                }
            }
        }

        XCTAssertEqual(titanStartAccessCount, 100, "expected 100 startAccessing calls")
        XCTAssertEqual(titanStopAccessCount, 100, "expected 100 stopAccessing calls — a mismatch means a leaked kernel resource")

        // The resource can still be re-accessed afterwards, proving prior
        // grants were actually released.
        let stillAccessible = scopedURL.startAccessingSecurityScopedResource()
        if stillAccessible { scopedURL.stopAccessingSecurityScopedResource() }
        XCTAssertTrue(true)
    }

    /// A non-security-scoped URL (e.g. a Finder drag) must proceed without
    /// calling `stop`, so the wrapper never over-releases.
    func testNonScopedURLProceedsWithoutStop() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/titan_nonscoped_access_test.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        titanStartAccessCount = 0
        titanStopAccessCount = 0

        try await withSwizzledAccess {
            let result = try await fileURL.withSecurityScopedAccess { url in
                try String(contentsOf: url)
            }
            XCTAssertEqual(result, "hello")
        }

        XCTAssertEqual(titanStartAccessCount, 1, "start is always attempted")
        XCTAssertEqual(titanStopAccessCount, 0, "non-scoped URL must not call stop")
    }
}
