import Foundation

enum PlayState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case error(String)
    
    static func == (lhs: PlayState, rhs: PlayState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading),
             (.playing, .playing), (.paused, .paused),
             (.seeking, .seeking):
            return true
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
}
