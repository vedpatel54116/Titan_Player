import XCTest
@testable import TitanPlayer

@MainActor
final class BookmarkManagerTests: XCTestCase {
    private let defaultsKey = "SecurityScopedBookmarks"

    private func makeStore() -> BookmarkStore {
        BookmarkStore()
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testInitiallyNoAccessedURL() {
        let store = makeStore()
        XCTAssertNil(store.currentlyAccessedURL)
    }

    func testCreateBookmarkStoresInDefaults() {
        let store = makeStore()
        let testURL = URL(fileURLWithPath: "/tmp/test_create_bookmark.txt")

        store.createBookmark(for: testURL)

        let bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]
        XCTAssertNotNil(bookmarks)
        XCTAssertNotNil(bookmarks?[testURL.path])
    }

    func testRemoveBookmarkClearsFromDefaults() {
        let store = makeStore()

        UserDefaults.standard.set(
            ["test_path": Data([0x01])],
            forKey: defaultsKey
        )

        store.removeBookmark(for: "test_path")

        let bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]
        XCTAssertTrue(bookmarks?.isEmpty ?? true)
    }

    func testResolveBookmarkReturnsNilForMissingEntry() {
        let store = makeStore()
        let result = store.resolveBookmark(for: "/nonexistent/path")
        XCTAssertNil(result)
    }

    func testStopAccessingClearsURL() {
        let store = makeStore()
        let testURL = URL(fileURLWithPath: "/tmp/test.txt")
        store.createBookmark(for: testURL)
        if let resolved = store.resolveBookmark(for: testURL.path) {
            _ = store.startAccessing(resolved)
        }

        store.stopAccessing()

        XCTAssertNil(store.currentlyAccessedURL)
    }

    func testStopAccessingDoesNothingWhenNoURL() {
        let store = makeStore()

        store.stopAccessing()

        XCTAssertNil(store.currentlyAccessedURL)
    }
}
