import AVFAudio

protocol FormatDecoder {
    func canDecode(_ format: AudioFormatType) -> Bool
    func decode(buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer
}

enum FormatDecoderError: Error {
    case unsupportedFormat
    case decodingFailed(Error)
    case invalidBuffer
}
