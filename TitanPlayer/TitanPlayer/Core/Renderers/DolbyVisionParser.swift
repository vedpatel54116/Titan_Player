import Foundation
import CoreMedia

class DolbyVisionParser {
    
    // MARK: - Public Methods
    
    func parseMetadata(from sampleBuffer: CMSampleBuffer,
                       profile: DolbyVisionProfile) -> DolbyVisionMetadata? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]] else {
            return nil
        }
        
        for attachment in attachments {
            if let metadataData = attachment["DolbyVisionMetadata"] as? Data {
                return parseDolbyVisionData(metadataData, profile: profile)
            }
        }
        
        return nil
    }
    
    func parseRPUData(_ rpuData: Data, profile: DolbyVisionProfile) -> DolbyVisionRPUMetadata? {
        guard rpuData.count >= 5 else { return nil }
        
        let reader = DataReader(data: rpuData)
        
        do {
            let sceneRefreshFlag = try reader.readBits(1) == 1
            let targetMaxLum = try reader.readBits(16)
            let targetMinLum = try reader.readBits(16)
            
            var trimPasses: [DolbyVisionTrimPass] = []
            // Each trim pass is 48 bits. The RPU trailer carries a 64-bit
            // active-area offset block, so stop reading trim passes once only
            // the trailing offset block (or less) remains. Reading to EOF would
            // have consumed those offsets as bogus trim passes.
            while reader.remainingBits > 64 {
                let percentile = try reader.readBits(8)
                let targetMax = try reader.readBits(16)
                let targetMin = try reader.readBits(16)
                let targetIndex = try reader.readBits(8)
                
                let trimInfo = DolbyVisionTrimInfo(
                    percentile: UInt8(percentile),
                    targetMaxLuminance: UInt16(targetMax),
                    targetMinLuminance: UInt16(targetMin)
                )
                
                let trimPass = DolbyVisionTrimPass(
                    trimInfo: trimInfo,
                    targetDisplayIndex: UInt8(targetIndex)
                )
                
                trimPasses.append(trimPass)
            }
            
            var activeAreaOffsets: DolbyVisionActiveAreaOffsets? = nil
            if reader.remainingBits == 64 {
                let top = try reader.readBits(16)
                let bottom = try reader.readBits(16)
                let left = try reader.readBits(16)
                let right = try reader.readBits(16)
                
                activeAreaOffsets = DolbyVisionActiveAreaOffsets(
                    top: UInt16(top),
                    bottom: UInt16(bottom),
                    left: UInt16(left),
                    right: UInt16(right)
                )
            }
            
            return DolbyVisionRPUMetadata(
                sceneRefreshFlag: sceneRefreshFlag,
                targetDisplayMaxLuminance: UInt16(targetMaxLum),
                targetDisplayMinLuminance: UInt16(targetMinLum),
                trimPasses: trimPasses,
                activeAreaOffsets: activeAreaOffsets
            )
        } catch {
            return nil
        }
    }
    
    // MARK: - Private Methods
    
    private func parseDolbyVisionData(_ data: Data, profile: DolbyVisionProfile) -> DolbyVisionMetadata? {
        guard data.count >= 10 else { return nil }
        
        let reader = DataReader(data: data)
        
        do {
            let blColorSpace = try reader.readBits(8)
            let blTransferChar = try reader.readBits(8)
            let blColorPrimaries = try reader.readBits(8)
            
            let blVideoSignalInfo = DolbyVisionVideoSignalInfo(
                colorSpace: DolbyVisionColorSpace(rawValue: UInt8(blColorSpace)) ?? .bt2020,
                transferCharacteristic: DolbyVisionTransferCharacteristic(rawValue: UInt8(blTransferChar)) ?? .pq,
                colorPrimaries: DolbyVisionColorPrimaries(rawValue: UInt8(blColorPrimaries)) ?? .bt2020
            )
            
            var elVideoSignalInfo: DolbyVisionVideoSignalInfo? = nil
            if profile.supportsDualLayer && data.count >= 16 {
                let elColorSpace = try reader.readBits(8)
                let elTransferChar = try reader.readBits(8)
                let elColorPrimaries = try reader.readBits(8)
                _ = try reader.readBits(8)
                
                elVideoSignalInfo = DolbyVisionVideoSignalInfo(
                    colorSpace: DolbyVisionColorSpace(rawValue: UInt8(elColorSpace)) ?? .bt2020,
                    transferCharacteristic: DolbyVisionTransferCharacteristic(rawValue: UInt8(elTransferChar)) ?? .pq,
                    colorPrimaries: DolbyVisionColorPrimaries(rawValue: UInt8(elColorPrimaries)) ?? .bt2020
                )
            }
            
            let rpuData = data[data.startIndex + reader.currentByteOffset..<data.endIndex]
            guard let rpuMetadata = parseRPUData(Data(rpuData), profile: profile) else {
                return nil
            }
            
            return DolbyVisionMetadata(
                profile: profile,
                blVideoSignalInfo: blVideoSignalInfo,
                elVideoSignalInfo: elVideoSignalInfo,
                rpuMetadata: rpuMetadata
            )
        } catch {
            return nil
        }
    }
    
    func selectTrimPass(for metadata: DolbyVisionMetadata,
                        displayCapabilities: DisplayCapabilities) -> DolbyVisionTrimPass? {
        let targetLuminance = displayCapabilities.maxEDRLuminance
        
        var bestMatch: DolbyVisionTrimPass? = nil
        var smallestDifference: Float = Float.greatestFiniteMagnitude
        
        for trimPass in metadata.rpuMetadata.trimPasses {
            let diff = abs(Float(trimPass.trimInfo.targetMaxLuminance) - targetLuminance)
            if diff < smallestDifference {
                smallestDifference = diff
                bestMatch = trimPass
            }
        }
        
        return bestMatch
    }
    
    func generateToneMappingParams(for metadata: DolbyVisionMetadata,
                                    trimPass: DolbyVisionTrimPass?,
                                    displayCapabilities: DisplayCapabilities) -> DolbyVisionToneMappingParams {
        let targetMaxLum = displayCapabilities.maxEDRLuminance
        let sourceMaxLum = Float(metadata.rpuMetadata.targetDisplayMaxLuminance)
        let sourceMinLum = Float(metadata.rpuMetadata.targetDisplayMinLuminance)
        
        let luminanceScale = targetMaxLum / max(sourceMaxLum, 1.0)
        let minLuminanceScale = 0.001 / max(sourceMinLum, 0.001)
        
        var saturationScale: Float = 1.0
        if let trimPass = trimPass {
            saturationScale = calculateSaturationScale(for: trimPass, metadata: metadata)
        }
        
        return DolbyVisionToneMappingParams(
            luminanceScale: luminanceScale,
            minLuminanceScale: minLuminanceScale,
            saturationScale: saturationScale,
            contrastAdjustment: calculateContrastAdjustment(metadata: metadata, displayCapabilities: displayCapabilities),
            brightnessAdjustment: calculateBrightnessAdjustment(metadata: metadata, trimPass: trimPass)
        )
    }
    
    private func calculateSaturationScale(for trimPass: DolbyVisionTrimPass,
                                           metadata: DolbyVisionMetadata) -> Float {
        let targetLuminance = Float(trimPass.trimInfo.targetMaxLuminance)
        let sourceLuminance = Float(metadata.rpuMetadata.targetDisplayMaxLuminance)
        
        let ratio = targetLuminance / max(sourceLuminance, 1.0)
        return min(max(ratio * 0.95, 0.8), 1.1)
    }
    
    private func calculateContrastAdjustment(metadata: DolbyVisionMetadata,
                                              displayCapabilities: DisplayCapabilities) -> Float {
        let targetRatio = displayCapabilities.maxEDRLuminance / 1000.0
        return min(max(targetRatio * 0.1, -0.2), 0.2)
    }
    
    private func calculateBrightnessAdjustment(metadata: DolbyVisionMetadata,
                                                trimPass: DolbyVisionTrimPass?) -> Float {
        guard let trimPass = trimPass else { return 0.0 }
        
        let percentile = Float(trimPass.trimInfo.percentile) / 100.0
        return (percentile - 0.5) * 0.1
    }
}

// MARK: - Supporting Types

struct DolbyVisionToneMappingParams {
    let luminanceScale: Float
    let minLuminanceScale: Float
    let saturationScale: Float
    let contrastAdjustment: Float
    let brightnessAdjustment: Float
}
