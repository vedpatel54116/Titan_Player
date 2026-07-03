import XCTest
@testable import TitanPlayer

@MainActor
final class SubtitleManagerTests: XCTestCase {

    private var manager: SubtitleManager!

    override func setUp() {
        super.setUp()
        manager = SubtitleManager()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Time filtering

    func test_update_filtersEventsByCurrentTime() {
        let events = [
            SubtitleEvent(
                startTime: 1.0, endTime: 3.0,
                text: AttributedString("First"),
                position: .bottom, style: .default
            ),
            SubtitleEvent(
                startTime: 5.0, endTime: 7.0,
                text: AttributedString("Second"),
                position: .bottom, style: .default
            ),
            SubtitleEvent(
                startTime: 10.0, endTime: 12.0,
                text: AttributedString("Third"),
                position: .bottom, style: .default
            )
        ]

        let track = SubtitleTrack(
            name: "test.srt",
            language: "en",
            isDefault: true,
            events: events
        )
        manager.setActiveTrack(track)

        // Time before all events
        manager.update(for: 0.5)
        XCTAssertTrue(manager.currentEvents.isEmpty)

        // Time during first event
        manager.update(for: 2.0)
        XCTAssertEqual(manager.currentEvents.count, 1)
        XCTAssertEqual(String(manager.currentEvents[0].text.characters), "First")

        // Time between first and second
        manager.update(for: 4.0)
        XCTAssertTrue(manager.currentEvents.isEmpty)

        // Time during second event
        manager.update(for: 6.0)
        XCTAssertEqual(manager.currentEvents.count, 1)
        XCTAssertEqual(String(manager.currentEvents[0].text.characters), "Second")

        // Time after all events
        manager.update(for: 15.0)
        XCTAssertTrue(manager.currentEvents.isEmpty)
    }

    func test_update_returnsEmptyWhenNoActiveTrack() {
        manager.update(for: 1.0)
        XCTAssertTrue(manager.currentEvents.isEmpty)
        XCTAssertNil(manager.currentBitmap)
    }

    func test_update_clearsEventsWhenTrackCleared() {
        let events = [
            SubtitleEvent(
                startTime: 0.0, endTime: 5.0,
                text: AttributedString("Visible"),
                position: .bottom, style: .default
            )
        ]
        let track = SubtitleTrack(name: "test.srt", language: nil, isDefault: true, events: events)
        manager.setActiveTrack(track)

        manager.update(for: 2.0)
        XCTAssertEqual(manager.currentEvents.count, 1)

        manager.clear()
        manager.update(for: 2.0)
        XCTAssertTrue(manager.currentEvents.isEmpty)
    }

    // MARK: - SRT parsing via loadSubtitle

    func test_loadSubtitle_parsesSRT() throws {
        let srtContent = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello, world!

        2
        00:00:05,000 --> 00:00:07,000
        Second subtitle

        3
        00:00:10,500 --> 00:00:12,000
        Third subtitle
        """

        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("test_\(UUID().uuidString).srt")
        try srtContent.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try manager.loadSubtitle(url: fileURL)

        XCTAssertEqual(manager.availableTracks.count, 1)
        let track = manager.availableTracks[0]
        XCTAssertEqual(track.name, fileURL.lastPathComponent)
        XCTAssertEqual(track.events.count, 3)

        // Verify first event
        XCTAssertEqual(track.events[0].startTime, 1.0)
        XCTAssertEqual(track.events[0].endTime, 3.0)
        XCTAssertEqual(String(track.events[0].text.characters), "Hello, world!")

        // Verify second event
        XCTAssertEqual(track.events[1].startTime, 5.0)
        XCTAssertEqual(track.events[1].endTime, 7.0)
        XCTAssertEqual(String(track.events[1].text.characters), "Second subtitle")

        // Verify third event
        XCTAssertEqual(track.events[2].startTime, 10.5)
        XCTAssertEqual(track.events[2].endTime, 12.0)
        XCTAssertEqual(String(track.events[2].text.characters), "Third subtitle")

        // Active track should be set automatically
        XCTAssertNotNil(manager.activeTrack)
        XCTAssertEqual(manager.activeTrack?.name, track.name)
    }

    func test_loadSubtitle_multipleTracks() throws {
        let srt1 = """
        1
        00:00:01,000 --> 00:00:03,000
        English
        """
        let srt2 = """
        1
        00:00:02,000 --> 00:00:04,000
        French
        """

        let tmpDir = FileManager.default.temporaryDirectory
        let url1 = tmpDir.appendingPathComponent("en_\(UUID().uuidString).srt")
        let url2 = tmpDir.appendingPathComponent("fr_\(UUID().uuidString).srt")
        try srt1.write(to: url1, atomically: true, encoding: .utf8)
        try srt2.write(to: url2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        try manager.loadSubtitle(url: url1)
        try manager.loadSubtitle(url: url2)

        XCTAssertEqual(manager.availableTracks.count, 2)
        // First track should be active by default
        XCTAssertEqual(manager.activeTrack?.name, url1.lastPathComponent)
    }

    func test_loadSubtitle_unsupportedFormat() {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("test_\(UUID().uuidString).xyz")
        try? "data".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertThrowsError(try manager.loadSubtitle(url: fileURL)) { error in
            XCTAssertTrue(error is MediaError)
        }
    }

    // MARK: - Time filtering edge cases

    func test_update_atExactBoundaryTimes() {
        let events = [
            SubtitleEvent(
                startTime: 2.0, endTime: 5.0,
                text: AttributedString("Boundary"),
                position: .bottom, style: .default
            )
        ]
        let track = SubtitleTrack(name: "test.srt", language: nil, isDefault: true, events: events)
        manager.setActiveTrack(track)

        // At exact start time — should be included (time >= startTime)
        manager.update(for: 2.0)
        XCTAssertEqual(manager.currentEvents.count, 1)

        // At exact end time — should be included (time <= endTime)
        manager.update(for: 5.0)
        XCTAssertEqual(manager.currentEvents.count, 1)

        // Just before start
        manager.update(for: 1.999)
        XCTAssertTrue(manager.currentEvents.isEmpty)

        // Just after end
        manager.update(for: 5.001)
        XCTAssertTrue(manager.currentEvents.isEmpty)
    }

    func test_update_overlappingEvents() {
        let events = [
            SubtitleEvent(
                startTime: 1.0, endTime: 5.0,
                text: AttributedString("First"),
                position: .bottom, style: .default
            ),
            SubtitleEvent(
                startTime: 3.0, endTime: 7.0,
                text: AttributedString("Second"),
                position: .bottom, style: .default
            )
        ]
        let track = SubtitleTrack(name: "test.srt", language: nil, isDefault: true, events: events)
        manager.setActiveTrack(track)

        // Overlapping region (3.0–5.0)
        manager.update(for: 4.0)
        XCTAssertEqual(manager.currentEvents.count, 2)
    }
}
