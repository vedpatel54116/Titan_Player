import Foundation
import CoreMedia
import CoreVideo

// MARK: - Zero-Copy Buffer Manager

class ZeroCopyBufferManager {
    private let pixelBufferPool: CVPixelBufferPool?
    private let bufferLock = NSLock()
    private var availableBuffers: [CMSampleBuffer] = []
    
    init(pixelBufferPool: CVPixelBufferPool? = nil) {
        self.pixelBufferPool = pixelBufferPool
    }
    
    // MARK: - Sample Buffer Creation
    
    func createSampleBuffer(from packet: MediaPacket,
                            formatDescription: CMVideoFormatDescription) throws -> CMSampleBuffer {
        // Create block buffer from packet data
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr, let blockBuffer = blockBuffer else {
            throw DecoderError.bufferCreationFailed(status)
        }
        
        // Copy packet data into block buffer
        try packet.data.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else {
                throw DecoderError.bufferCreationFailed(-1)
            }
            
            let destinationPointer = UnsafeMutableRawPointer(mutating: baseAddress)
            CMBlockBufferReplaceDataBytes(
                with: destinationPointer,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: packet.data.count
            )
        }
        
        // Create timing info
        var timingInfo = CMSampleTimingInfo(
            duration: packet.duration,
            presentationTimeStamp: packet.timestamp,
            decodeTimeStamp: .invalid
        )
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw DecoderError.bufferCreationFailed(sampleStatus)
        }
        
        return sampleBuffer
    }
    
    // MARK: - Pixel Buffer Pool Management
    
    func createPixelBufferPool(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        )
        
        return status == noErr ? pool : nil
    }
    
    func getPixelBuffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool = pool else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        
        return status == noErr ? pixelBuffer : nil
    }
    
    // MARK: - Sample Buffer to Pixel Buffer Conversion
    
    func convertSampleBufferToPixelBuffer(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        return CMSampleBufferGetImageBuffer(sampleBuffer)
    }
    
    // MARK: - Buffer Reuse
    
    func enqueueBuffer(_ buffer: CMSampleBuffer) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        if availableBuffers.count < 10 {
            availableBuffers.append(buffer)
        }
    }
    
    func dequeueBuffer() -> CMSampleBuffer? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        return availableBuffers.popLast()
    }
    
    // MARK: - Annex-B → AVCC Conversion
    
    static func annexBToAVCC(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        
        let bytes = [UInt8](data)
        var result: [UInt8] = []
        var i = 0
        var foundStartCode = false
        
        while i < bytes.count {
            if i + 3 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                foundStartCode = true
                let naluStart = i + 4
                let naluEnd = findNextStartCode(in: bytes, from: naluStart)
                let naluLen = naluEnd - naluStart
                
                if naluLen > 0 {
                    let len = UInt32(naluLen)
                    result.append(UInt8((len >> 24) & 0xFF))
                    result.append(UInt8((len >> 16) & 0xFF))
                    result.append(UInt8((len >> 8) & 0xFF))
                    result.append(UInt8(len & 0xFF))
                    result.append(contentsOf: bytes[naluStart..<naluEnd])
                }
                i = naluEnd
            } else if i + 2 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                foundStartCode = true
                let naluStart = i + 3
                let naluEnd = findNextStartCode(in: bytes, from: naluStart)
                let naluLen = naluEnd - naluStart
                
                if naluLen > 0 {
                    let len = UInt32(naluLen)
                    result.append(UInt8((len >> 24) & 0xFF))
                    result.append(UInt8((len >> 16) & 0xFF))
                    result.append(UInt8((len >> 8) & 0xFF))
                    result.append(UInt8(len & 0xFF))
                    result.append(contentsOf: bytes[naluStart..<naluEnd])
                }
                i = naluEnd
            } else {
                i += 1
            }
        }
        
        if !foundStartCode {
            let len = UInt32(bytes.count)
            result.append(UInt8((len >> 24) & 0xFF))
            result.append(UInt8((len >> 16) & 0xFF))
            result.append(UInt8((len >> 8) & 0xFF))
            result.append(UInt8(len & 0xFF))
            result.append(contentsOf: bytes)
        }
        
        return Data(result)
    }
    
    private static func findNextStartCode(in bytes: [UInt8], from start: Int) -> Int {
        var j = start + 1
        while j < bytes.count {
            if j + 3 < bytes.count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 0 && bytes[j+3] == 1 {
                return j
            }
            if j + 2 < bytes.count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 1 {
                return j
            }
            j += 1
        }
        return bytes.count
    }
}

// MARK: - Format Converter

struct FormatConverter {
    static func convertToSampleBuffer(_ pixelBuffer: CVPixelBuffer,
                                       formatDescription: CMVideoFormatDescription,
                                       timingInfo: CMSampleTimingInfo) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timingInfoCopy = timingInfo
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfoCopy,
            sampleBufferOut: &sampleBuffer
        )
        
        return status == noErr ? sampleBuffer : nil
    }
    
    static func convertToPixelBuffer(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        return CMSampleBufferGetImageBuffer(sampleBuffer)
    }
}
