import XCTest
@testable import TitanPlayer

final class PlayStateTransitionTests: XCTestCase {

    /// Normalizes a state to a stable key, treating all `.failed` payloads
    /// identically so pairs can be compared without depending on the error.
    private func key(_ state: PlaybackState) -> String {
        switch state {
        case .failed:
            return "failed"
        default:
            return "\(state)"
        }
    }

    /// Every `(from, to)` pair permitted by the transition table.
    private func allowedPairs() -> [(PlaybackState, PlaybackState)] {
        let ready = PlaybackState.ready(duration: .zero)
        let buffering = PlaybackState.buffering(progress: 0.5)
        let seeking = PlaybackState.seeking(to: .zero)
        let failed = PlaybackState.failed(error: .invalidURL)
        return [
            (.idle, .opening),
            (.opening, ready), (.opening, failed), (.opening, .idle),
            (ready, .playing), (ready, seeking), (ready, failed), (ready, .idle),
            (.playing, .paused), (.playing, seeking), (.playing, buffering),
            (.playing, failed), (.playing, .idle),
            (.paused, .playing), (.paused, seeking), (.paused, failed), (.paused, .idle),
            (buffering, .playing), (buffering, .paused), (buffering, failed), (buffering, .idle),
            (seeking, .playing), (seeking, .paused), (seeking, ready),
            (seeking, failed), (seeking, .idle),
            (failed, .idle), (failed, .opening),
        ]
    }

    func testAllAllowedTransitions() {
        for (from, to) in allowedPairs() {
            XCTAssertTrue(from.canTransition(to: to),
                          "expected \(from) -> \(to) to be allowed")
        }
    }

    func testAllOtherPairsBlocked() {
        let allStates: [PlaybackState] = [
            .idle, .opening,
            .ready(duration: .zero),
            .playing, .paused,
            .buffering(progress: 0.5),
            .seeking(to: .zero),
            .failed(error: .invalidURL),
        ]
        let allowed = Set(allowedPairs().map { "\(key($0.0))|\(key($0.1))" })

        for from in allStates {
            for to in allStates {
                let pairKey = "\(key(from))|\(key(to))"
                if !allowed.contains(pairKey) {
                    XCTAssertFalse(from.canTransition(to: to),
                                   "expected \(from) -> \(to) to be blocked")
                }
            }
        }
    }
}
