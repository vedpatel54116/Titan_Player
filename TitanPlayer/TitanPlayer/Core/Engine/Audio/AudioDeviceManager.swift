import Foundation
import AVFAudio

final class AudioDeviceManager {
    static let shared = AudioDeviceManager()
    
    private var activeEngineCount = 0
    private let lock = NSLock()
    
    var audioEngine: AVAudioEngine { sharedEngine }
    
    private let sharedEngine = AVAudioEngine()
    
    func acquireEngine() -> AVAudioEngine {
        lock.lock()
        defer { lock.unlock() }
        activeEngineCount += 1
        return sharedEngine
    }
    
    func releaseEngine() {
        lock.lock()
        defer { lock.unlock() }
        activeEngineCount -= 1
        if activeEngineCount <= 0 {
            sharedEngine.stop()
        }
    }
}
