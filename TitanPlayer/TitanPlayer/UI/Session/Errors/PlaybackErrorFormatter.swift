import Foundation

enum PlaybackErrorFormatter {
    static func describe(_ error: Error, for url: URL) -> String {
        let name = url.lastPathComponent
        if let playbackError = error as? PlaybackError {
            switch playbackError {
            case .invalidURL:
                return "Failed to open \"\(name)\": The file URL is invalid."
            case .noPlayableTracks:
                return "Failed to open \"\(name)\": The file contains no playable video or audio tracks. The codec may be unsupported."
            case .assetLoadFailed(let underlying):
                return "Failed to open \"\(name)\": \(underlying.localizedDescription)"
            case .assetLoadFailedWithStatus(let status, let underlying):
                return "Failed to open \"\(name)\": OSStatus \(status) — \(underlying.localizedDescription)"
            case .decodingFailed(let underlying, _):
                return "Failed to open \"\(name)\": Decoding failed — \(underlying.localizedDescription)"
            case .audioOutputFailed(let underlying):
                return "Failed to open \"(name)\": Audio output failed — \(underlying.localizedDescription)"
            case .rateNotSupported:
                return "Failed to open \"\(name)\": The playback rate is not supported by this file."
            case .seekFailed:
                return "Failed to open \"\(name)\": Seeking within the file failed."
            case .networkTimeout:
                return "Failed to open \"\(name)\": Network request timed out."
            case .audioFormatUnsupported:
                return "Failed to open \"\(name)\": The audio format is not supported."
            case .gpuDeviceLost:
                return "Failed to open \"\(name)\": GPU device lost."
            case .drmUnsupported:
                return "Failed to open \"\(name)\": DRM protection is not supported."
            }
        }
        if let mediaError = error as? MediaError {
            return "Failed to open \"\(name)\": \(mediaError.message)"
        }
        if let decoderError = error as? DecoderError {
            switch decoderError {
            case .unsupportedCodec(let codec):
                return "Failed to open \"\(name)\": Unsupported codec \"\(codec)\". No decoder is available for this format."
            case .sessionNotConfigured:
                return "Failed to open \"\(name)\": The decoder session was not properly configured."
            case .bufferCreationFailed(let status):
                return "Failed to open \"\(name)\": Could not allocate a decoding buffer (OSStatus \(status))."
            case .noFramesDecoded:
                return "Failed to open \"\(name)\": The decoder could not decode any frames from this file."
            case .hardwareFailure:
                return "Failed to open \"\(name)\": Hardware decoder failure. The device may not support this codec."
            case .softwareFailure:
                return "Failed to open \"\(name)\": Software decoder failure."
            }
        }
        if let nsError = error as NSError? {
            let domain = nsError.domain
            let code = nsError.code
            if domain == "NSOSStatusErrorDomain" && code == -2004 {
                return "Failed to open \"\(name)\": File format not recognized. The container may be corrupted or unsupported."
            }
            if domain == "AVFoundationErrorDomain" {
                switch code {
                case -11800:
                    return "Failed to open \"\(name)\": AVFoundation could not open the file. The format may be unsupported or the file may be corrupted."
                case -11821:
                    return "Failed to open \"\(name)\": Decoding failed. The video codec in this file is not supported."
                default:
                    break
                }
            }
        }
        return "Failed to open \"\(name)\": \(error.localizedDescription)"
    }
}
