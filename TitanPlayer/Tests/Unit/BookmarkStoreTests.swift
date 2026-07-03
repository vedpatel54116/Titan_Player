import XCTest
@testable import TitanPlayer

@MainActor
final class BookmarkStoreTests: XCTestCase {
    private let defaultsKey = "SecurityScopedBookmarks"
    private var store: BookmarkStore!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        store = BookmarkStore()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func test_resolveBookmark_returnsNilForMissingPath() {
        let result = store.resolveBookmark(for: "/nonexistent/path")
        XCTAssertNil(result)
    }

    func test_removeBookmark_clearsFromDefaults() {
        UserDefaults.standard.set(
            ["some/path": Data([0x01, 0x02])],
            forKey: defaultsKey
        )

        store.removeBookmark(for: "some/path")

        let remaining = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]
        XCTAssertTrue(remaining?.isEmpty ?? true)
    }

    func test_resolveBookmark_removesStaleEntry() throws {
        let fakePath = "/tmp/stale_bookmark_\(UUID().uuidString).txt"
        let bogusData = try URL(
            fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).txt"
        ).bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set([fakePath: bogusData], forKey: defaultsKey)

        let result = store.resolveBookmark(for: fakePath)

        XCTAssertNil(result)
        let remaining = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]
        XCTAssertNil(remaining?[fakePath])
    }

    func test_stopAccessingCurrentResource_noOpWhenNil() {
        store.stopAccessingCurrentResource()
        XCTAssertNil(store.currentlyAccessedURL)
    }

    func test_createAndResolveBookmark_roundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkStoreTest_\(UUID().uuidString).txt")
        try "hello".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard tmp.startAccessingSecurityScopedResource() else {
            throw XCTSkip("Cannot create security-scoped bookmark in non-sandbox context")
        }
        defer { tmp.stopAccessingSecurityScopedResource() }

        store.createBookmark(for: tmp)
        let resolved = store.resolveBookmark(for: tmp.path)

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.path, tmp.path)
    }
}
