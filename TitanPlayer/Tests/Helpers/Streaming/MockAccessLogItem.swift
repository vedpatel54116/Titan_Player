import Foundation
@testable import TitanPlayer

@MainActor
final class MockAccessLogItem: AccessLogProviding {
    var observedBitrate: Double = 0
    var indicatedBitrate: Double = 0
    var numberOfStalls: Int = 0
    var numberOfDroppedFrames: Int = 0
}
