import AVFoundation
import CoreMedia
import AudioToolbox

class AVFoundationDemuxer: MediaDemuxing {
    private var asset: AVURLAsset?
    private var assetReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var startTime: CMTime = .zero
    
    func open(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw MediaError(code: .decodingFailed, message: "Failed to create asset reader")
        }
        self.assetReader = reader
        
        let duration = try await asset.load(.duration)
        
        let avVideoTracks = try await asset.loadTracks(withMediaType: .video)
        var videoTracks: [VideoTrackInfo] = []
        var foundVideoOutput: AVAssetReaderTrackOutput?
        
        for track in avVideoTracks {
            let formatDescs = try? await track.load(.formatDescriptions)
            let codecName = extractVideoCodecName(from: formatDescs)
            let isHDR = detectHDR(from: formatDescs)
            let nominalRate = try? await track.load(.nominalFrameRate)
            let naturalSize = try? await track.load(.naturalSize)
            
            let trackInfo = VideoTrackInfo(
                codec: codecName,
                width: Int(naturalSize?.width ?? 0),
                height: Int(naturalSize?.height ?? 0),
                frameRate: Double(nominalRate ?? 0),
                isHDR: isHDR,
                extradata: nil
            )
            videoTracks.append(trackInfo)
            
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            if reader.canAdd(output) {
                reader.add(output)
                foundVideoOutput = output
            }
        }
        
        let avAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioTracks: [AudioTrackInfo] = []
        var foundAudioOutput: AVAssetReaderTrackOutput?
        
        for track in avAudioTracks {
            let formatDescs = try? await track.load(.formatDescriptions)
            let codecName = extractAudioCodecName(from: formatDescs)
            let audioProps = extractAudioProperties(from: formatDescs)
            let languageCode = try? await track.load(.languageCode)
            
            let trackInfo = AudioTrackInfo(
                codec: codecName,
                sampleRate: audioProps.sampleRate,
                channels: audioProps.channels,
                language: languageCode
            )
            audioTracks.append(trackInfo)
            
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            if reader.canAdd(output) {
                reader.add(output)
                foundAudioOutput = output
            }
        }
        
        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            throw MediaError(
                code: .unsupportedFormat,
                message: "No playable tracks found — unsupported codec inside \(url.pathExtension.uppercased()) file"
            )
        }
        
        self.videoOutput = foundVideoOutput
        self.audioOutput = foundAudioOutput
        reader.startReading()
        
        return MediaInfo(
            duration: duration,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: [],
            format: url.pathExtension.uppercased()
        )
    }
    
    func nextPacket() async throws -> MediaPacket {
        guard let reader = assetReader, reader.status == .reading else {
            throw MediaError(code: .decodingFailed, message: "Reader not ready")
        }
        
        if let output = videoOutput, let sampleBuffer = output.copyNextSampleBuffer() {
            return try buildPacket(from: sampleBuffer, streamIndex: 0)
        }
        
        if let output = audioOutput, let sampleBuffer = output.copyNextSampleBuffer() {
            return try buildPacket(from: sampleBuffer, streamIndex: 1)
        }
        
        throw MediaError(code: .decodingFailed, message: "No more packets")
    }
    
    private func buildPacket(from sampleBuffer: CMSampleBuffer, streamIndex: Int) throws -> MediaPacket {
        let timestamp = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetOutputDuration(sampleBuffer)
        
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw MediaError(code: .decodingFailed, message: "No data buffer")
        }
        
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        )
        
        guard status == noErr, let pointer = dataPointer else {
            throw MediaError(code: .decodingFailed, message: "Failed to get data pointer")
        }
        
        let data = Data(bytes: pointer, count: length)
        
        return MediaPacket(
            streamIndex: streamIndex,
            data: data,
            timestamp: timestamp,
            duration: duration,
            isKeyFrame: true
        )
    }
    
    func seek(to time: CMTime) async throws {
        startTime = time
    }
    
    func close() {
        assetReader?.cancelReading()
        assetReader = nil
    }
    
    // MARK: - Private Helpers
    
    private func extractVideoCodecName(from formatDescs: [CMFormatDescription]?) -> String {
        guard let desc = formatDescs?.first else { return "unknown" }
        let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
        return fourCharCodeToString(mediaSubType)
    }
    
    private func extractAudioCodecName(from formatDescs: [CMFormatDescription]?) -> String {
        guard let desc = formatDescs?.first else { return "unknown" }
        let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
        return fourCharCodeToString(mediaSubType)
    }
    
    private struct AudioProperties {
        let sampleRate: Int
        let channels: Int
    }
    
    private func extractAudioProperties(from formatDescs: [CMFormatDescription]?) -> AudioProperties {
        guard let desc = formatDescs?.first else {
            return AudioProperties(sampleRate: 44100, channels: 2)
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return AudioProperties(sampleRate: 44100, channels: 2)
        }
        return AudioProperties(
            sampleRate: Int(asbd.mSampleRate),
            channels: Int(asbd.mChannelsPerFrame)
        )
    }
    
    private func detectHDR(from formatDescs: [CMFormatDescription]?) -> Bool {
        guard let desc = formatDescs?.first else { return false }
        guard let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] else { return false }
        return extensions["ContainsHDRMetadata"] as? Bool ?? false
    }
    
    private func fourCharCodeToString(_ code: OSType) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: code >> 24),
            UInt8(truncatingIfNeeded: code >> 16),
            UInt8(truncatingIfNeeded: code >> 8),
            UInt8(truncatingIfNeeded: code)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }
}
