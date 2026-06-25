import XCTest
@testable import TitanPlayer

final class DemuxerTests: XCTestCase {
    func testAVFoundationDemuxerOpensFile() async throws {
        let demuxer = AVFoundationDemuxer()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
        
        let info = try await demuxer.open(url: testURL)
        
        XCTAssertFalse(info.videoTracks.isEmpty)
        XCTAssertEqual(info.format, "MP4")
        
        demuxer.close()
    }
    
    func testFFmpegDemuxerOpensFile() async throws {
        let demuxer = FFmpegDemuxer()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
        
        let info = try await demuxer.open(url: testURL)
        
        XCTAssertNotNil(info.format)
        
        demuxer.close()
    }
    
    func testDemuxerThrowsOnMissingFile() async {
        let demuxer = AVFoundationDemuxer()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/file.mp4")
        
        do {
            _ = try await demuxer.open(url: fakeURL)
            XCTFail("Should throw error")
        } catch {
            XCTAssertTrue(error is MediaError)
        }
    }
}
