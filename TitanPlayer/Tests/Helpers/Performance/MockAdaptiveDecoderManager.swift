import Foundation
@testable import TitanPlayer

final class MockAdaptiveDecoderManagerSink {
    enum Preference: Sendable, Equatable {
        case preferHardware
        case preferSoftware
        case neutral
    }
    private(set) var lastPreference: Preference?
    private(set) var callCount: Int = 0

    func record(_ p: Preference) {
        lastPreference = p
        callCount += 1
    }
}
