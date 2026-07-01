import Foundation
import AVFAudio

final class MockAudioRenderer: AudioRenderer {
    private(set) var scheduledBuffers: [AVAudioPCMBuffer] = []
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var didPause = false
    private(set) var didResume = false

    var volume: Float = 1.0
    var currentTime: TimeInterval = 0

    func start() throws {
        didStart = true
    }

    func stop() {
        didStop = true
    }

    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at time: TimeInterval?) {
        scheduledBuffers.append(buffer)
        currentTime = time ?? currentTime
    }

    func pause() {
        didPause = true
    }

    func resume() {
        didResume = true
    }
}
