import Foundation
import AVFoundation

final class NotImplementedDASHPlayer: DASHPlayer {
    func playableAsset(for url: URL) async throws -> AVURLAsset {
        throw StreamingError.dashNotSupported(url)
    }

    func streamSession(for url: URL) async throws -> DASHStreamSession {
        throw StreamingError.dashNotSupported(url)
    }

    var currentVariants: [StreamingQuality] {
        get async { [] }
    }
}
