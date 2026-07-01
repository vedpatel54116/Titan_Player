import Foundation
import AVFoundation

protocol DASHPlayer: AnyObject {
    func playableAsset(for url: URL) async throws -> AVURLAsset
    func streamSession(for url: URL) async throws -> DASHStreamSession
    var currentVariants: [StreamingQuality] { get async }
}
