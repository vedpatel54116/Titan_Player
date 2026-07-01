import Foundation

enum TelemetryEvent {
    case playbackFailed(
        codec: String,
        resolution: String,
        errorCode: String,
        source: PlaybackSource
    )
    
    case hdrModeUsed(
        mode: HDRMode,
        duration: TimeInterval
    )
    
    case performanceSnapshot(
        averageCPU: Double,
        averageGPU: Double,
        resolution: String,
        codec: String
    )
    
    case audioFormatUsed(
        format: AudioFormat,
        sampleRate: Int,
        bitDepth: Int
    )
}

enum PlaybackSource: String, Sendable {
    case local
    case hls
    case dash
}

enum HDRMode: String, Sendable {
    case hdr10
    case dolbyVision
    case hlghdr
}

enum AudioFormat: String, Sendable {
    case atmos
    case stereo
    case spatial
    case surround5_1
}
