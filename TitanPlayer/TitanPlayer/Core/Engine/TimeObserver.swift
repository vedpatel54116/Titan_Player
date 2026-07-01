import Foundation
import CoreMedia
import Combine

class TimeObserver: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var progress: Double = 0
    
    private var timer: Timer?
    private var startTime: Date?
    
    func startObserving() {
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateTime()
        }
    }
    
    func stopObserving() {
        timer?.invalidate()
        timer = nil
    }
    
    func update(to timestamp: CMTime) {
        currentTime = CMTimeGetSeconds(timestamp)
        updateProgress()
    }

    func seekTo(_ time: Double) {
        currentTime = time
        updateProgress()
    }
    
    private func updateTime() {
        guard let startTime = startTime else { return }
        currentTime = Date().timeIntervalSince(startTime)
        updateProgress()
    }
    
    private func updateProgress() {
        guard duration > 0 else { return }
        progress = currentTime / duration
    }
    
    func reset() {
        currentTime = 0
        startTime = Date()
    }
}
