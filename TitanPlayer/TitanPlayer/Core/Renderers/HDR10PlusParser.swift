import Foundation
import CoreMedia

class HDR10PlusParser {
    
    // MARK: - Public Methods
    
    func parseMetadata(from sampleBuffer: CMSampleBuffer) -> HDR10PlusMetadata? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]] else {
            return nil
        }
        
        for attachment in attachments {
            if let metadataData = attachment["HDR10PlusMetadata"] as? Data {
                return parseHDR10PlusData(metadataData)
            }
        }
        
        return nil
    }
    
    func parseSEIMessages(_ seiMessages: [SEIMessage]) -> [HDR10PlusMetadata] {
        var metadataList: [HDR10PlusMetadata] = []
        
        for message in seiMessages {
            if message.type == .hdr10Plus, let data = message.payload {
                if let metadata = parseHDR10PlusData(data) {
                    metadataList.append(metadata)
                }
            }
        }
        
        return metadataList
    }
    
    // MARK: - Private Parsing Methods
    
    private func parseHDR10PlusData(_ data: Data) -> HDR10PlusMetadata? {
        guard data.count >= 11 else { return nil }
        
        let reader = DataReader(data: data)
        
        do {
            let curveExponent = try reader.readBits(5)
            let kneePointX = try reader.readBits(13)
            let kneePointY = try reader.readBits(13)
            let numAnchors = try reader.readBits(6)
            
            var anchors: [UInt16] = []
            for _ in 0..<numAnchors {
                let anchor = try reader.readBits(10)
                anchors.append(UInt16(anchor))
            }
            
            var saturationMap: [UInt8] = []
            while reader.hasMoreBits {
                let value = try reader.readBits(8)
                saturationMap.append(UInt8(value))
            }
            
            return HDR10PlusMetadata(
                curveExponent: UInt8(curveExponent),
                kneePointX: UInt16(kneePointX),
                kneePointY: UInt16(kneePointY),
                numBezierCurveAnchors: UInt8(numAnchors),
                bezierCurveAnchors: anchors,
                colorSaturationMap: saturationMap
            )
        } catch {
            return nil
        }
    }
    
    func generateDynamicToneMappingParams(for metadata: HDR10PlusMetadata,
                                           displayCapabilities: DisplayCapabilities) -> DynamicToneMappingParams {
        let targetLuminance = displayCapabilities.maxEDRLuminance
        let normalizedKneePoint = Float(metadata.kneePointX) / 4095.0
        let normalizedKneePointY = Float(metadata.kneePointY) / 4095.0
        
        let luminanceRatio = targetLuminance / 1000.0
        let adjustedKneePoint = normalizedKneePoint * luminanceRatio
        
        return DynamicToneMappingParams(
            kneePoint: adjustedKneePoint,
            compressionRatio: normalizedKneePointY,
            colorSaturationScale: Float(metadata.colorSaturationMap.first ?? 128) / 128.0,
            brightnessAdjustment: calculateBrightnessAdjustment(metadata: metadata, targetLuminance: targetLuminance)
        )
    }
    
    private func calculateBrightnessAdjustment(metadata: HDR10PlusMetadata,
                                                targetLuminance: Float) -> Float {
        let contentLuminance = Float(metadata.kneePointY) / 4095.0 * 1000.0
        let luminanceDelta = targetLuminance - contentLuminance
        return luminanceDelta / targetLuminance * 0.5
    }
}

// MARK: - Supporting Types

struct DynamicToneMappingParams {
    let kneePoint: Float
    let compressionRatio: Float
    let colorSaturationScale: Float
    let brightnessAdjustment: Float
}

enum SEIMessageType {
    case hdr10Plus
    case dolbyVision
    case masteringDisplayColorVolume
    case contentLightLevel
    case unknown
}

struct SEIMessage {
    let type: SEIMessageType
    let payload: Data?
    let timestamp: CMTime
}

// MARK: - Data Reader Helper

class DataReader {
    private let data: Data
    private var bitOffset: Int = 0
    
    init(data: Data) {
        self.data = data
    }
    
    var hasMoreBits: Bool {
        return bitOffset < data.count * 8
    }
    
    var currentByteOffset: Int {
        return bitOffset / 8
    }
    
    func readBits(_ count: Int) throws -> UInt32 {
        guard count > 0 && count <= 32 else {
            throw DataReaderError.invalidBitCount(count)
        }
        
        var result: UInt32 = 0
        var bitsRead = 0
        
        while bitsRead < count && bitOffset < data.count * 8 {
            let byteIndex = bitOffset / 8
            let bitIndex = 7 - (bitOffset % 8)
            
            guard byteIndex < data.count else {
                throw DataReaderError.endOfData
            }
            
            let byte = data[data.startIndex + byteIndex]
            let bit = (byte >> bitIndex) & 1
            
            result = (result << 1) | UInt32(bit)
            bitOffset += 1
            bitsRead += 1
        }
        
        return result
    }
    
    func readBytes(_ count: Int) throws -> Data {
        guard count > 0 else {
            throw DataReaderError.invalidBitCount(count * 8)
        }
        
        let startByte = bitOffset / 8
        let endByte = startByte + count
        
        guard endByte <= data.count else {
            throw DataReaderError.endOfData
        }
        
        let startIndex = data.startIndex + startByte
        let endIndex = data.startIndex + endByte
        
        bitOffset = endByte * 8
        return data[startIndex..<endIndex]
    }
}

enum DataReaderError: Error {
    case invalidBitCount(Int)
    case endOfData
}
