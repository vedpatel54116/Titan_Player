import AVFAudio

enum AudioFormatType: Equatable {
    case pcm
    case aac
    case ac3
    case eac3
    case dts
    case unknown
}

private let kAudioFormatDTSCoreAudio: UInt32 = 0x44545320 // 'DTS '

final class AudioFormatDetector {
    func detectFormat(from format: AVAudioFormat) -> AudioFormatType {
        if format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64 {
            return .pcm
        }

        let streamDescription = format.streamDescription
        let formatID = streamDescription.pointee.mFormatID

        switch formatID {
        case kAudioFormatMPEG4AAC:
            return .aac
        case kAudioFormatAC3:
            return .ac3
        case kAudioFormatEnhancedAC3:
            return .eac3
        case kAudioFormatDTSCoreAudio:
            return .dts
        default:
            return .unknown
        }
    }
}
