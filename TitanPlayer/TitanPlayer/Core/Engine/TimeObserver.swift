import Foundation
import CoreMedia
import Combine
import os.log

class TimeObserver: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var progress: Double = 0
    @Published var audioVideoDrift: TimeInterval = 0
    private var driftLogStartTime: Date?
    private let driftLogDuration: TimeInterval = 5.0
    private let logger = Logger(subsystem: "com.titanplayer", category: "Sync")
    
    func startObserving() {
        driftLogStartTime = nil
    }

    func stopObserving() {
    }
    
    func update(to timestamp: CMTime) {
        currentTime = CMTimeGetSeconds(timestamp)
        updateProgress()
    }

    func seekTo(_ time: Double) {
        currentTime = time
        updateProgress()
    }
    
    func updateDrift(audioTime: TimeInterval, videoTime: TimeInterval) {
        let drift = videoTime - audioTime
        audioVideoDrift = drift
        
        if driftLogStartTime == nil {
            driftLogStartTime = Date()
        }
        
        let elapsed = Date().timeIntervalSince(driftLogStartTime!)
        if elapsed <= driftLogDuration {
            logger.debug("[Sync] Drift: \(String(format: "%.3f", drift * 1000))ms (audio: \(String(format: "%.3f", audioTime))s, video: \(String(format: "%.3f", videoTime))s)")
        }
    }
    
    private func updateProgress() {
        guard duration > 0 else { return }
        progress = currentTime / duration
    }
    
    func reset() {
        currentTime = 0
    }
}
