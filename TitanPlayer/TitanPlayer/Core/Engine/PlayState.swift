import Foundation

enum PlaybackState: Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case seeking
    case error(String)
    
    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready),
             (.playing, .playing), (.paused, .paused), (.ended, .ended),
             (.seeking, .seeking):
            return true
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
    
    func canTransition(to target: PlaybackState) -> Bool {
        switch (self, target) {
        case (.idle, .loading),
             (.loading, .ready), (.loading, .error),
             (.ready, .playing), (.ready, .seeking),
             (.playing, .paused), (.playing, .ended), (.playing, .seeking),
             (.paused, .playing), (.paused, .seeking),
             (.ended, .ready), (.ended, .loading),
             (.seeking, .playing), (.seeking, .paused):
            return true
        default:
            return false
        }
    }
}
