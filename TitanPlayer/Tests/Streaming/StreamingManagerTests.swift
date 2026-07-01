import XCTest
import AVFoundation
import Combine
@testable import TitanPlayer

@MainActor
final class StreamingManagerTests: XCTestCase {
    private var manager: StreamingManager!
    private var hls: MockHLSPlayer!
    private var cache: MockStreamingCache!
    private var monitor: MockNetworkMonitor!
    private var stats: MockStatsPublisher!
    private var player: AVPlayer!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        hls = MockHLSPlayer()
        cache = MockStreamingCache()
        monitor = MockNetworkMonitor()
        stats = MockStatsPublisher()
        player = AVPlayer()
        manager = StreamingManager(
            hlsPlayer: hls,
            cache: cache,
            networkMonitor: monitor,
            statsPublisher: stats
        )
        cancellables = []
    }

    override func tearDown() {
        manager.detach()
        manager = nil
        player = nil
        cancellables = []
        super.tearDown()
    }

    func testIsStreamingHLSUsesPathExtension() {
        XCTAssertTrue(manager.isStreaming(.m3u8))
        XCTAssertFalse(manager.isStreaming(.mp4))
        XCTAssertFalse(manager.isStreaming(.mov))
    }

    func testAttachHLSBindsStatsProvider() {
        manager.attach(player: player)
        XCTAssertTrue(stats.wasAttached)
    }

    func testAttachDetachesAndResets() {
        manager.attach(player: player)
        manager.detach()
        XCTAssertTrue(stats.wasDetached)
    }

    func testLoadNonHLSIsNoOp() {
        let url = URL(fileURLWithPath: "/tmp/not_here.mp4")
        manager.load(url: url)
        XCTAssertEqual(hls.makeAssetCalls.count, 0)
    }

    func testLoadHLSInvokesHLSPlayer() {
        let url = URL(string: "https://example.com/x.m3u8")!
        manager.load(url: url)
        XCTAssertEqual(hls.makeAssetCalls.first, url)
    }

    func testMPDURLErrorState() {
        let url = URL(string: "https://example.com/x.mpd")!
        manager.load(url: url)
        if case .error(let msg) = manager.streamingState {
            XCTAssertTrue(msg.contains("DASH"))
        } else {
            XCTFail("Expected error state for DASH")
        }
    }
}
