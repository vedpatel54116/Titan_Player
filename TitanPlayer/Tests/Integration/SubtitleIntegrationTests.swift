import XCTest
@testable import TitanPlayer

@MainActor
final class SubtitleIntegrationTests: XCTestCase {
    func testSubtitleManagerLoadsSRT() throws {
        let manager = SubtitleManager()
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello, world!
        """
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.srt")
        try srtContent.write(to: tempURL, atomically: true, encoding: .utf8)
        
        try manager.loadSubtitle(url: tempURL)
        
        XCTAssertEqual(manager.availableTracks.count, 1)
        XCTAssertEqual(manager.activeTrack?.name, "test.srt")
        
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    func testSubtitleManagerUpdatesForTime() throws {
        let manager = SubtitleManager()
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        First subtitle
        
        2
        00:00:05,000 --> 00:00:08,000
        Second subtitle
        """
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.srt")
        try srtContent.write(to: tempURL, atomically: true, encoding: .utf8)
        
        try manager.loadSubtitle(url: tempURL)
        
        manager.update(for: 2.0)
        XCTAssertEqual(manager.currentEvents.count, 1)
        
        manager.update(for: 6.0)
        XCTAssertEqual(manager.currentEvents.count, 1)
        
        manager.update(for: 9.0)
        XCTAssertTrue(manager.currentEvents.isEmpty)
        
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    func testSubtitleManagerClearsTracks() throws {
        let manager = SubtitleManager()
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        Test
        """
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.srt")
        try srtContent.write(to: tempURL, atomically: true, encoding: .utf8)
        
        try manager.loadSubtitle(url: tempURL)
        manager.clear()
        
        XCTAssertTrue(manager.availableTracks.isEmpty)
        XCTAssertNil(manager.activeTrack)
        XCTAssertTrue(manager.currentEvents.isEmpty)
        
        try? FileManager.default.removeItem(at: tempURL)
    }
}
