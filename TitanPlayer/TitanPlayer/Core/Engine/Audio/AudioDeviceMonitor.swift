import Foundation
import CoreAudio
import AVFAudio
import os.log

final class AudioDeviceMonitor {
    static let shared = AudioDeviceMonitor()
    
    private let logger = Logger(subsystem: "com.titanplayer", category: "AudioDevice")
    private var isMonitoring = false
    private var propertyListenerBlock: AudioObjectPropertyListenerBlock?
    
    private weak var audioEngine: AVAudioEngine?
    
    private init() {}
    
    func startMonitoring(engine: AVAudioEngine) {
        self.audioEngine = engine
        
        guard !isMonitoring else { return }
        isMonitoring = true
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        propertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange()
        }
        
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            propertyListenerBlock!
        )
        
        if status != noErr {
            logger.warning("Failed to register audio device listener: \(status)")
            isMonitoring = false
        }
    }
    
    func stopMonitoring() {
        guard isMonitoring, let block = propertyListenerBlock else { return }
        
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        
        isMonitoring = false
        propertyListenerBlock = nil
    }
    
    private func handleDeviceChange() {
        logger.info("Audio output device changed")
        
        guard let engine = audioEngine else { return }
        guard engine.isRunning else { return }
        
        engine.pause()
        
        do {
            try engine.start()
            logger.info("Audio engine restarted after device change")
        } catch {
            logger.error("Failed to restart audio engine: \(error.localizedDescription)")
        }
    }
    
    deinit {
        stopMonitoring()
    }
}
