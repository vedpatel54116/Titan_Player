import Foundation
import AVFAudio

protocol AudioRenderer: AnyObject {
    var volume: Float { get set }
    var currentTime: TimeInterval { get }
    
    func start() throws
    func stop()
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at time: TimeInterval?)
    func pause()
    func resume()
}

class AVAudioEngineRenderer: AudioRenderer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = max(0, min(1, newValue)) }
    }
    
    var currentTime: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return Double(playerTime.sampleTime) / Double(playerTime.sampleRate)
    }
    
    func start() throws {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        try engine.start()
        playerNode.play()
    }
    
    func stop() {
        playerNode.stop()
        engine.stop()
    }
    
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at time: TimeInterval?) {
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
    
    func pause() {
        playerNode.pause()
    }
    
    func resume() {
        playerNode.play()
    }
}
