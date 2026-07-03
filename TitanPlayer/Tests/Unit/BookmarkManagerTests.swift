import XCTest
@testable import TitanPlayer

@MainActor
final class BookmarkManagerTests: XCTestCase {
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

    func testInitiallyNoAccessedURL() {
        XCTAssertNil(store.currentlyAccessedURL)
    }

    func testCreateBookmarkStoresInDefaults() {
        let testURL = URL(fileURLWithPath: "/tmp/test_create_bookmark.txt")

        store.createBookmark(for: testURL)

        let bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]
        XCTAssertNotNil(bookmarks)
        XCTAssertNotNil(bookmarks?[testURL.path])
    }

    func testRemoveBookmarkClearsFromDefaults() {
        UserDefaults.standard.set(
            ["test_path": Data([0x01])],
            forKey: defaultsKey
        )

        store.removeBookmark(for: "test_path")

        let bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]
        XCTAssertTrue(bookmarks?.isEmpty ?? true)
    }

    func testResolveBookmarkReturnsNilForMissingEntry() {
        let result = store.resolveBookmark(for: "/nonexistent/path")
        XCTAssertNil(result)
    }

    func testStopAccessingDoesNothingWhenNoURL() {
        store.stopAccessingCurrentResource()
        XCTAssertNil(store.currentlyAccessedURL)
    }
}
