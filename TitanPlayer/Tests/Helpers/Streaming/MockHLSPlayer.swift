import Foundation
import AVFoundation
@testable import TitanPlayer

final class MockHLSPlayer: HLSPlayerProtocol {
    var makeAssetCalls: [URL] = []
    var purgeCount = 0
    var presetAsset: AVURLAsset?

    func makeAsset(url: URL) -> AVURLAsset {
        makeAssetCalls.append(url)
        return presetAsset ?? AVURLAsset(url: url)
    }

    func purge() { purgeCount += 1 }
}
