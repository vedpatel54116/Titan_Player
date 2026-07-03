import Foundation
import Combine

final class SeekThrottler {
    private let engine: PlaybackEngine
    private let subject = PassthroughSubject<TimeInterval, Never>()
    private var cancellables = Set<AnyCancellable>()
    
    init(engine: PlaybackEngine, minInterval: TimeInterval = 0.25) {
        self.engine = engine
        
        subject
            .debounce(for: .seconds(minInterval), scheduler: DispatchQueue.main)
            .sink { [weak engine] time in
                Task { @MainActor in
                    await engine?.seek(to: time)
                }
            }
            .store(in: &cancellables)
    }
    
    func scheduleSeek(to time: TimeInterval) {
        subject.send(time)
    }
}
