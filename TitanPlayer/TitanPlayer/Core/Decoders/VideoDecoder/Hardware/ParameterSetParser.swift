import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

// MARK: - FourCC Helper

private func fourCharCode(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for char in string.unicodeScalars.prefix(4) {
        result = (result << 8) | char.value
    }
    return result
}

// MARK: - Parameter Set Parser

enum ParameterSetParser {
    
    // MARK: - Main Entry Point
    
    static func parseFormatDescription(extradata: Data?,
                                       codec: VideoCodec,
                                       width: Int,
                                       height: Int) -> CMVideoFormatDescription? {
        switch codec {
        case .h264:
            if let extradata = extradata {
                if isAvcC(extradata) {
                    return parseH264(extradata: extradata)
                } else {
                    return parseAnnexB(extradata: extradata, codec: .h264)
                }
            }
            return createBasicFormatDescription(codec: codec, width: width, height: height)
            
        case .hevc:
            if let extradata = extradata {
                if isHvcC(extradata) {
                    return parseHEVC(extradata: extradata)
                } else {
                    return parseAnnexB(extradata: extradata, codec: .hevc)
                }
            }
            return createBasicFormatDescription(codec: codec, width: width, height: height)
            
        case .vp9, .av1, .mpeg2, .vc1:
            return createBasicFormatDescription(codec: codec, width: width, height: height)
        }
    }
    
    // MARK: - H.264 avcC Parsing
    
    static func parseH264(extradata: Data) -> CMVideoFormatDescription? {
        guard extradata.count >= 7 else { return nil }
        
        let bytes = [UInt8](extradata)
        guard bytes[0] == 0x01 else { return nil }
        
        let numSPS = Int(bytes[5] & 0x1F)
        guard numSPS > 0 else { return nil }
        
        var spsArray: [[UInt8]] = []
        var offset = 6
        
        for _ in 0..<numSPS {
            guard offset + 2 <= bytes.count else { return nil }
            let spsLen = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard offset + spsLen <= bytes.count, spsLen > 0 else { return nil }
            spsArray.append(Array(bytes[offset..<(offset + spsLen)]))
            offset += spsLen
        }
        
        guard offset < bytes.count else { return nil }
        let numPPS = Int(bytes[offset])
        offset += 1
        
        var ppsArray: [[UInt8]] = []
        for _ in 0..<numPPS {
            guard offset + 2 <= bytes.count else { return nil }
            let ppsLen = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard offset + ppsLen <= bytes.count, ppsLen > 0 else { return nil }
            ppsArray.append(Array(bytes[offset..<(offset + ppsLen)]))
            offset += ppsLen
        }
        
        guard !spsArray.isEmpty, !ppsArray.isEmpty else { return nil }
        
        return createH264FormatDescription(spsArray: spsArray, ppsArray: ppsArray)
    }
    
    // MARK: - HEVC hvcC Parsing
    
    static func parseHEVC(extradata: Data) -> CMVideoFormatDescription? {
        guard extradata.count >= 23 else { return nil }
        
        let bytes = [UInt8](extradata)
        guard bytes[0] == 0x01 else { return nil }
        
        let numArrays = Int(bytes[15])
        var offset = 16
        
        var vpsArray: [[UInt8]] = []
        var spsArray: [[UInt8]] = []
        var ppsArray: [[UInt8]] = []
        
        for _ in 0..<numArrays {
            guard offset + 3 <= bytes.count else { return nil }
            let nalType = bytes[offset] & 0x3F
            offset += 1
            let numNalus = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            
            for _ in 0..<numNalus {
                guard offset + 2 <= bytes.count else { return nil }
                let naluLen = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + naluLen <= bytes.count, naluLen > 0 else { return nil }
                let nalu = Array(bytes[offset..<(offset + naluLen)])
                offset += naluLen
                
                switch nalType {
                case 32: vpsArray.append(nalu)
                case 33: spsArray.append(nalu)
                case 34: ppsArray.append(nalu)
                default: break
                }
            }
        }
        
        guard !vpsArray.isEmpty, !spsArray.isEmpty, !ppsArray.isEmpty else { return nil }
        
        return createHEVCFormatDescription(vpsArray: vpsArray, spsArray: spsArray, ppsArray: ppsArray)
    }
    
    // MARK: - Annex-B Parsing
    
    static func parseAnnexB(extradata: Data, codec: VideoCodec) -> CMVideoFormatDescription? {
        let nalus = splitAnnexBNALUs(extradata)
        guard !nalus.isEmpty else { return nil }
        
        switch codec {
        case .h264:
            var spsArray: [[UInt8]] = []
            var ppsArray: [[UInt8]] = []
            
            for nalu in nalus {
                guard !nalu.isEmpty else { continue }
                let nalType = nalu[0] & 0x1F
                switch nalType {
                case 7: spsArray.append(nalu)
                case 8: ppsArray.append(nalu)
                default: break
                }
            }
            
            guard !spsArray.isEmpty, !ppsArray.isEmpty else { return nil }
            return createH264FormatDescription(spsArray: spsArray, ppsArray: ppsArray)
            
        case .hevc:
            var vpsArray: [[UInt8]] = []
            var spsArray: [[UInt8]] = []
            var ppsArray: [[UInt8]] = []
            
            for nalu in nalus {
                guard !nalu.isEmpty else { continue }
                let nalType = (nalu[0] >> 1) & 0x3F
                switch nalType {
                case 32: vpsArray.append(nalu)
                case 33: spsArray.append(nalu)
                case 34: ppsArray.append(nalu)
                default: break
                }
            }
            
            guard !vpsArray.isEmpty, !spsArray.isEmpty, !ppsArray.isEmpty else { return nil }
            return createHEVCFormatDescription(vpsArray: vpsArray, spsArray: spsArray, ppsArray: ppsArray)
            
        default:
            return nil
        }
    }
    
    // MARK: - Format Description Creation
    
    private static func createH264FormatDescription(spsArray: [[UInt8]], ppsArray: [[UInt8]]) -> CMVideoFormatDescription? {
        // Flatten all SPS and PPS into one contiguous buffer for stable pointers
        var allBytes: [UInt8] = []
        var spsRanges: [(offset: Int, length: Int)] = []
        var ppsRanges: [(offset: Int, length: Int)] = []
        
        for sps in spsArray {
            spsRanges.append((allBytes.count, sps.count))
            allBytes.append(contentsOf: sps)
        }
        for pps in ppsArray {
            ppsRanges.append((allBytes.count, pps.count))
            allBytes.append(contentsOf: pps)
        }
        
        // H.264 API: SPS first, then PPS, all in one pointer array
        let totalParams = spsArray.count + ppsArray.count
        var formatDescription: CMVideoFormatDescription?
        
        allBytes.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            
            for r in spsRanges {
                pointers.append(base.advanced(by: r.offset))
                sizes.append(r.length)
            }
            for r in ppsRanges {
                pointers.append(base.advanced(by: r.offset))
                sizes.append(r.length)
            }
            
            pointers.withUnsafeBufferPointer { ptrBuf in
                sizes.withUnsafeBufferPointer { sizeBuf in
                    _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: totalParams,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: sizeBuf.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }
        }
        
        return formatDescription
    }
    
    private static func createHEVCFormatDescription(vpsArray: [[UInt8]], spsArray: [[UInt8]], ppsArray: [[UInt8]]) -> CMVideoFormatDescription? {
        // Flatten VPS, SPS, PPS into one contiguous buffer
        var allBytes: [UInt8] = []
        var vpsRanges: [(offset: Int, length: Int)] = []
        var spsRanges: [(offset: Int, length: Int)] = []
        var ppsRanges: [(offset: Int, length: Int)] = []
        
        for vps in vpsArray {
            vpsRanges.append((allBytes.count, vps.count))
            allBytes.append(contentsOf: vps)
        }
        for sps in spsArray {
            spsRanges.append((allBytes.count, sps.count))
            allBytes.append(contentsOf: sps)
        }
        for pps in ppsArray {
            ppsRanges.append((allBytes.count, pps.count))
            allBytes.append(contentsOf: pps)
        }
        
        // HEVC API: VPS first, then SPS, then PPS
        let totalParams = vpsArray.count + spsArray.count + ppsArray.count
        var formatDescription: CMVideoFormatDescription?
        
        allBytes.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            
            var pointers: [UnsafePointer<UInt8>] = []
            var sizes: [Int] = []
            
            for r in vpsRanges {
                pointers.append(base.advanced(by: r.offset))
                sizes.append(r.length)
            }
            for r in spsRanges {
                pointers.append(base.advanced(by: r.offset))
                sizes.append(r.length)
            }
            for r in ppsRanges {
                pointers.append(base.advanced(by: r.offset))
                sizes.append(r.length)
            }
            
            pointers.withUnsafeBufferPointer { ptrBuf in
                sizes.withUnsafeBufferPointer { sizeBuf in
                    _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: totalParams,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: sizeBuf.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }
        }
        
        return formatDescription
    }
    
    private static func createBasicFormatDescription(codec: VideoCodec, width: Int, height: Int) -> CMVideoFormatDescription? {
        let codecType: CMVideoCodecType
        switch codec {
        case .h264:  codecType = kCMVideoCodecType_H264
        case .hevc:  codecType = kCMVideoCodecType_HEVC
        case .vp9:   codecType = kCMVideoCodecType_VP9
        case .av1:   codecType = kCMVideoCodecType_AV1
        case .mpeg2: codecType = kCMVideoCodecType_MPEG2Video
        case .vc1:   codecType = CMVideoCodecType(fourCharCode("vc-1"))
        }
        
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        return status == noErr ? formatDescription : nil
    }
    
    // MARK: - Annex-B Splitting
    
    static func splitAnnexBNALUs(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var nalus: [[UInt8]] = []
        var i = 0
        
        while i < bytes.count {
            var startCodeLen = 0
            if i + 3 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                startCodeLen = 4
            } else if i + 2 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                startCodeLen = 3
            } else {
                i += 1
                continue
            }
            
            let naluStart = i + startCodeLen
            
            var j = naluStart + 1
            while j < bytes.count {
                if j + 3 < bytes.count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 0 && bytes[j+3] == 1 {
                    break
                }
                if j + 2 < bytes.count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 1 {
                    break
                }
                j += 1
            }
            
            let naluEnd = j < bytes.count ? j : bytes.count
            if naluEnd > naluStart {
                nalus.append(Array(bytes[naluStart..<naluEnd]))
            }
            
            i = j
        }
        
        return nalus
    }
    
    // MARK: - Format Detection
    
    private static func isAvcC(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        return data[0] == 0x01
    }
    
    private static func isHvcC(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        return data[0] == 0x01
    }
}
