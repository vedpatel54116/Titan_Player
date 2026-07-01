import Foundation
@testable import TitanPlayer

final class MockMetalRendererCapSink {
    private(set) var lastCap: ResolutionCap?
    private(set) var callCount: Int = 0

    func record(_ cap: ResolutionCap) {
        lastCap = cap
        callCount += 1
    }
}

final class MockStreamingManagerCapSink {
    private(set) var lastBitrate: Int?
    private(set) var callCount: Int = 0

    func record(_ bitrate: Int) {
        lastBitrate = bitrate
        callCount += 1
    }
}

final class MockAudioEngineCapSink {
    private(set) var lastMode: AudioMode?
    private(set) var callCount: Int = 0

    func record(_ mode: AudioMode) {
        lastMode = mode
        callCount += 1
    }
}
