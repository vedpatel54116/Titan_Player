import Foundation
import Combine
import CoreMedia

final class TimeUpdatePublisher: ObservableObject {
    @Published var currentTime: CMTime = .zero
    @Published var displayTime: String = "0:00"
    
    private var cancellables = Set<AnyCancellable>()
    
    init(timeSource: AnyPublisher<CMTime, Never>) {
        timeSource
            .throttle(for: .seconds(1.0 / 60.0), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] time in
                self?.currentTime = time
                self?.displayTime = Self.formatTime(time.seconds)
            }
            .store(in: &cancellables)
    }
    
    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
