import Foundation
import AVFoundation
@testable import TitanPlayer

@MainActor
final class MockStatsPublisher: StatsPublisherProtocol, ObservableObject {
    var wasAttached = false
    var wasAttachedToItem: AVPlayerItem?
    var wasDetached = false

    func attach(item: AVPlayerItem) {
        wasAttached = true
        wasAttachedToItem = item
    }
    func attach(provider: any AccessLogProviding) {
        wasAttached = true
    }
    func detach() { wasDetached = true }
}
