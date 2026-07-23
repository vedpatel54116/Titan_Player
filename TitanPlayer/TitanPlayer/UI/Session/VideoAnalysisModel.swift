import Foundation

/// Master on/off gate for the video-analysis toolset (histogram, vectorscope,
/// waveform, audio metering).
///
/// When `isEnabled` is `false` the underlying `VideoAnalysisManager` must not
/// dispatch any compute work — see its `enabling` bridge — so the analysis
/// pipeline costs zero GPU even while frames keep flowing through the
/// `FrameStore`.
@MainActor
@Observable
final class VideoAnalysisModel {
    var isEnabled: Bool = true
}
