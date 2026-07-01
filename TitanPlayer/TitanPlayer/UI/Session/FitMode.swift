import Foundation

enum FitMode: Equatable {
    case fit
    case fill
    case stretch
}

func resolveFitMode(for info: MediaInfo) -> FitMode {
    guard let video = info.videoTracks.first else { return .fit }
    let aspect = Double(video.width) / Double(video.height)
    switch aspect {
    case 1.0..<1.4:   return .fit
    case 2.3...2.5:   return .fit
    default:          return .fit
    }
}
