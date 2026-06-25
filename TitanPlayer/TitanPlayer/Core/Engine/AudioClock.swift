import Foundation
import Combine

class AudioClock: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    
    var rate: Float = 1.0
    
    private var isRunning = false
    private var isPaused = false
    private var startMonotonic: TimeInterval = 0
    private var accumulatedTime: TimeInterval = 0
    private var pauseAccumulated: TimeInterval = 0
    private var timer: Timer?
    
    func start() {
        isRunning = true
        isPaused = false
        startMonotonic = ProcessInfo.processInfo.systemUptime
        accumulatedTime = 0
        pauseAccumulated = 0
        startTimer()
    }
    
    func stop() {
        isRunning = false
        isPaused = false
        stopTimer()
        currentTime = 0
    }
    
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        accumulatedTime = computeCurrentTime()
        stopTimer()
    }
    
    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        startMonotonic = ProcessInfo.processInfo.systemUptime
        pauseAccumulated = accumulatedTime
        startTimer()
    }
    
    func seek(to time: TimeInterval) {
        currentTime = time
        if isRunning && !isPaused {
            pauseAccumulated = time
            startMonotonic = ProcessInfo.processInfo.systemUptime
        } else {
            accumulatedTime = time
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func tick() {
        currentTime = computeCurrentTime()
    }
    
    private func computeCurrentTime() -> TimeInterval {
        let elapsed = (ProcessInfo.processInfo.systemUptime - startMonotonic) * Double(rate)
        return pauseAccumulated + elapsed
    }
}
