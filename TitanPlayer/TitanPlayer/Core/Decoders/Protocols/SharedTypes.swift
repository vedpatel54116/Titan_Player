import Foundation
import CoreMedia
import CoreVideo

struct MediaInfo {
    let duration: CMTime
    let videoTracks: [VideoTrackInfo]
    let audioTracks: [AudioTrackInfo]
    let subtitleTracks: [SubtitleTrackInfo]
    let format: String
}

struct VideoTrackInfo {
    let codec: String
    let width: Int
    let height: Int
    let frameRate: Double
    let isHDR: Bool
    let extradata: Data?
}

struct AudioTrackInfo {
    let codec: String
    let sampleRate: Int
    let channels: Int
    let language: String?
}

struct SubtitleTrackInfo {
    let codec: String
    let language: String?
    let isForced: Bool
}

struct MediaPacket {
    let streamIndex: Int
    let data: Data
    let timestamp: CMTime
    let duration: CMTime
    let isKeyFrame: Bool
}

enum MediaFrame {
    case video(VideoFrame)
    case audio(AudioFrame)
    case subtitle(SubtitleData)
}

struct VideoFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CMTime
    let duration: CMTime
    let colorSpace: ColorSpace
    let sampleBuffer: CMSampleBuffer?
}

enum ColorSpace {
    case sRGB
    case p3
    case bt2020
}

struct AudioFrame {
    let buffer: [Float]
    let format: AudioFormat
    let timestamp: CMTime
    let duration: CMTime
}

struct AudioFormat {
    let sampleRate: Int
    let channels: Int
    let isInterleaved: Bool
}

struct SubtitleData {
    let text: String
    let timestamp: CMTime
    let duration: CMTime
}

struct HDRMetadata {
    let type: HDRType
    let maxLuminance: Float
    let minLuminance: Float
}

enum HDRType {
    case hdr10
    case dolbyVision
    case hlg
}

struct MediaError: Error, LocalizedError {
    let code: ErrorCode
    let message: String
    
    enum ErrorCode: Int {
        case fileNotFound = 1
        case unsupportedFormat = 2
        case decodingFailed = 3
        case networkError = 4
    }
    
    var errorDescription: String? { message }
}
