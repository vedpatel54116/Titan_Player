import Foundation

enum TelemetryEvent {
    case playbackFailed(
        codec: String,
        resolution: String,
        errorCode: String,
        source: PlaybackSource
    )
    
    case hdrModeUsed(
        mode: TelemetryHDRMode,
        duration: TimeInterval
    )
    
    case performanceSnapshot(
        averageCPU: Double,
        averageGPU: Double,
        resolution: String,
        codec: String
    )
    
    case audioFormatUsed(
        format: TelemetryAudioFormat,
        sampleRate: Int,
        bitDepth: Int
    )

    case compatibilityModeActivated(
        reason: String,
        source: PlaybackSource
    )
}

enum PlaybackSource: String, Sendable {
    case local
    case hls
}

enum TelemetryHDRMode: String, Sendable {
    case hdr10
    case dolbyVision
    case hlg
}

enum TelemetryAudioFormat: String, Sendable {
    case atmos
    case stereo
    case spatial
    case surround5_1
}
