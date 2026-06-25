import XCTest
@testable import TitanPlayer

@MainActor
final class ViewModelTests: XCTestCase {
    func testPlayerViewModelInitializesWithIdleState() {
        let viewModel = PlayerViewModel()
        
        XCTAssertEqual(viewModel.playState, .idle)
        XCTAssertEqual(viewModel.volume, 1.0)
        XCTAssertFalse(viewModel.isMuted)
    }
    
    func testPlayerViewModelTogglePlayPause() {
        let viewModel = PlayerViewModel()
        
        viewModel.togglePlayPause()
        // Should still be idle since no media is loaded
        
        XCTAssertEqual(viewModel.playState, .idle)
    }
    
    func testPlayerViewModelVolumeClamping() {
        let viewModel = PlayerViewModel()
        
        viewModel.setVolume(1.5)
        XCTAssertEqual(viewModel.volume, 1.0)
        
        viewModel.setVolume(-0.5)
        XCTAssertEqual(viewModel.volume, 0.0)
    }
    
    func testLibraryViewModelCreatesPlaylist() {
        let viewModel = LibraryViewModel()
        
        viewModel.createPlaylist(name: "Test Playlist")
        
        XCTAssertEqual(viewModel.playlists.count, 1)
        XCTAssertEqual(viewModel.playlists[0].name, "Test Playlist")
    }
    
    func testLibraryViewModelAddsToPlaylist() {
        let viewModel = LibraryViewModel()
        viewModel.createPlaylist(name: "Test Playlist")
        
        let item = MediaItem(
            id: URL(fileURLWithPath: "/test.mp4"),
            url: URL(fileURLWithPath: "/test.mp4"),
            title: "Test",
            duration: 100,
            dateAdded: Date()
        )
        
        viewModel.addToPlaylist(viewModel.playlists[0], item: item)
        
        XCTAssertEqual(viewModel.playlists[0].items.count, 1)
    }
}
