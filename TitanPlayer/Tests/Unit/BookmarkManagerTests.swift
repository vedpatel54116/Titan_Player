import XCTest
@testable import TitanPlayer

@MainActor
final class BookmarkManagerTests: XCTestCase {
    private let defaultsKey = "SecurityScopedBookmarks"

    private func makeSession() -> PlaybackSession {
        PlaybackSession(videoRenderer: MockFrameRenderer(),
                        audioRenderer: MockAudioRenderer())
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
        let s = makeSession()
        XCTAssertNil(s.currentlyAccessedURL)
    }

    func testCreateBookmarkStoresInDefaults() {
        let s = makeSession()
        let testURL = URL(fileURLWithPath: "/tmp/test_create_bookmark.txt")

        s.createBookmark(for: testURL)

        let bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]
        XCTAssertNotNil(bookmarks)
        XCTAssertNotNil(bookmarks?[testURL.path])
    }

    func testRemoveBookmarkClearsFromDefaults() {
        let s = makeSession()

        UserDefaults.standard.set(
            ["test_path": Data([0x01])],
            forKey: defaultsKey
        )

        s.removeBookmark(for: "test_path")

        let bookmarks = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]
        XCTAssertTrue(bookmarks?.isEmpty ?? true)
    }

    func testResolveBookmarkReturnsNilForMissingEntry() {
        let s = makeSession()
        let result = s.resolveBookmark(for: "/nonexistent/path")
        XCTAssertNil(result)
    }

    func testStopAccessingClearsURL() {
        let s = makeSession()
        s.currentlyAccessedURL = URL(fileURLWithPath: "/tmp/test.txt")

        s.stopAccessingCurrentResource()

        XCTAssertNil(s.currentlyAccessedURL)
    }

    func testStopAccessingDoesNothingWhenNoURL() {
        let s = makeSession()
        s.currentlyAccessedURL = nil

        s.stopAccessingCurrentResource()

        XCTAssertNil(s.currentlyAccessedURL)
    }
}
