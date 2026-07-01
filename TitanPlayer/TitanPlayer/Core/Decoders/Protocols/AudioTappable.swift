import Foundation

typealias AudioTap = (AudioFrame) -> Void

@MainActor
protocol AudioTappable {
    var audioTap: AudioTap? { get set }
}
