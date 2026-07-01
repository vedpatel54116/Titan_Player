import Foundation

@MainActor
enum DASHPlayerFactory {
    static func player(for url: URL) -> DASHPlayer {
        DASHPlayerImpl()
    }
}
