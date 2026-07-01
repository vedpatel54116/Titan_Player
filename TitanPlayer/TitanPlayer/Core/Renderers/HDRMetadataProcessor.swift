import Foundation
import CoreMedia
import CoreVideo
import Metal
import simd
import os.log

class HDRMetadataProcessor {
    
    private let logger = Logger(subsystem: "com.titanplayer", category: "HDRMetadata")
    
    // MARK: - Properties
    
    private let hdr10PlusParser = HDR10PlusParser()
    private let dolbyVisionParser = DolbyVisionParser()
    private let passthroughManager = MetadataPassthroughManager()
    
    private var dynamicMetadata: [HDR10PlusMetadata] = []
    private var dolbyVisionMetadata: DolbyVisionMetadata?
    private var currentHDRMode: ExtendedHDRMode = .sdr
    private var processingConfig: HDRProcessingConfig = .default
    private var displayCapabilities: DisplayCapabilities?
    
    private var metadataHistory: [(timestamp: CMTime, metadata: ProcessedMetadata)] = []
    private let maxHistorySize = 100
    
    private var lastAppliedParams: AppliedHDRParams?
    private var targetParams: AppliedHDRParams?
    private var transitionStartTime: TimeInterval = 0
    private let transitionDuration: TimeInterval = 0.083
    
    // MARK: - Types
    
    struct ProcessedMetadata {
        let hdr10PlusParams: DynamicToneMappingParams?
        let dolbyVisionParams: DolbyVisionToneMappingParams?
        let selectedTrimPass: DolbyVisionTrimPass?
        let timestamp: CMTime
    }
    
    struct MetadataUpdate {
        let mode: ExtendedHDRMode
        let timestamp: CMTime
        let isDynamic: Bool
    }
    
    struct AppliedHDRParams {
        let kneePoint: Float
        let compressionRatio: Float
        let saturationScale: Float
        let brightnessAdjustment: Float
        let useDynamicMetadata: Bool
        let isDolbyVision: Bool
        let dvProfile: DolbyVisionProfile?
    }
    
    // MARK: - Public Methods
    
    func configure(with config: HDRProcessingConfig) {
        processingConfig = config
        passthroughManager.enablePassthrough(config.enableMetadataPassthrough)
    }
    
    func updateDisplayCapabilities(_ capabilities: DisplayCapabilities) {
        displayCapabilities = capabilities
    }
    
    func processMetadata(from sampleBuffer: CMSampleBuffer) -> MetadataUpdate? {
        var metadataChanged = false
        var newMode: ExtendedHDRMode = currentHDRMode
        
        if let hdr10PlusMetadata = hdr10PlusParser.parseMetadata(from: sampleBuffer) {
            dynamicMetadata.append(hdr10PlusMetadata)
            if dynamicMetadata.count > maxHistorySize {
                dynamicMetadata.removeFirst()
            }
            newMode = .hdr10Plus(hdr10PlusMetadata)
            metadataChanged = true
            logger.info("Detected HDR10+ Dynamic Metadata — kneePoint: \(String(format: "%.3f", hdr10PlusMetadata.kneePointX))")
        }
        
        if let dvMetadata = parseDolbyVisionMetadata(from: sampleBuffer) {
            dolbyVisionMetadata = dvMetadata
            newMode = .dolbyVision(dvMetadata)
            metadataChanged = true
            logger.info("Detected Dolby Vision Metadata — profile: \(dvMetadata.profile.rawValue)")
        }
        
        if let hdr10Metadata = parseHDR10Metadata(from: sampleBuffer) {
            newMode = .hdr10(hdr10Metadata)
            metadataChanged = true
            logger.info("Detected HDR10 Metadata — maxLum: \(String(format: "%.0f", hdr10Metadata.maxDisplayLuminance)), minLum: \(String(format: "%.4f", hdr10Metadata.minDisplayLuminance)), MaxCLL: \(String(format: "%.0f", hdr10Metadata.maxContentLightLevel)), MaxFALL: \(String(format: "%.0f", hdr10Metadata.maxFrameAverageLightLevel))")
        }
        
        guard metadataChanged else {
            logger.debug("No HDR metadata detected in sample buffer (SDR content)")
            return nil
        }
        
        currentHDRMode = newMode
        
        let processed = generateProcessedMetadata(for: newMode, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        metadataHistory.append((timestamp: processed.timestamp, metadata: processed))
        
        if metadataHistory.count > maxHistorySize {
            metadataHistory.removeFirst()
        }
        
        if processingConfig.enableMetadataPassthrough {
            passthroughToExternalDisplays(newMode, timestamp: processed.timestamp)
        }
        
        return MetadataUpdate(mode: newMode, timestamp: processed.timestamp, isDynamic: newMode.isDynamic)
    }
    
    func getProcessedMetadata(for timestamp: CMTime) -> ProcessedMetadata? {
        return metadataHistory.min(by: { lhs, rhs in
            let lhsDiff = abs(CMTimeGetSeconds(lhs.timestamp) - CMTimeGetSeconds(timestamp))
            let rhsDiff = abs(CMTimeGetSeconds(rhs.timestamp) - CMTimeGetSeconds(timestamp))
            return lhsDiff < rhsDiff
        })?.metadata
    }
    
    func getDynamicToneMappingParams(for timestamp: CMTime) -> DynamicToneMappingParams? {
        guard processingConfig.enableDynamicToneMapping else { return nil }
        
        guard let processed = getProcessedMetadata(for: timestamp),
              let params = processed.hdr10PlusParams else {
            return nil
        }
        
        return params
    }
    
    func getDolbyVisionToneMappingParams(for timestamp: CMTime) -> DolbyVisionToneMappingParams? {
        guard let processed = getProcessedMetadata(for: timestamp),
              let params = processed.dolbyVisionParams else {
            return nil
        }
        
        return params
    }
    
    func getCurrentHDRMode() -> ExtendedHDRMode {
        return currentHDRMode
    }
    
    func reset() {
        dynamicMetadata.removeAll()
        dolbyVisionMetadata = nil
        metadataHistory.removeAll()
        currentHDRMode = .sdr
        lastAppliedParams = nil
        targetParams = nil
        transitionStartTime = 0
    }
    
    // MARK: - Private Methods
    
    private func parseDolbyVisionMetadata(from sampleBuffer: CMSampleBuffer) -> DolbyVisionMetadata? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]] else {
            return nil
        }
        
        for attachment in attachments {
            if let profileValue = attachment["DolbyVisionProfile"] as? UInt8,
               let profile = DolbyVisionProfile(rawValue: profileValue) {
                return dolbyVisionParser.parseMetadata(from: sampleBuffer, profile: profile)
            }
        }
        
        return nil
    }
    
    private func parseHDR10Metadata(from sampleBuffer: CMSampleBuffer) -> HDR10Metadata? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]] else {
            return nil
        }
        
        for attachment in attachments {
            if let metadataDict = attachment["HDR10Metadata"] as? [String: Any],
               let maxLum = metadataDict["maxDisplayLuminance"] as? Float,
               let minLum = metadataDict["minDisplayLuminance"] as? Float {
                
                return HDR10Metadata(
                    displayPrimaries: (
                        red: SIMD2<Float>(0.708, 0.292),
                        green: SIMD2<Float>(0.170, 0.797),
                        blue: SIMD2<Float>(0.131, 0.046)
                    ),
                    whitePoint: SIMD2<Float>(0.3127, 0.3290),
                    maxDisplayLuminance: maxLum,
                    minDisplayLuminance: minLum,
                    maxContentLightLevel: metadataDict["maxContentLightLevel"] as? Float ?? maxLum,
                    maxFrameAverageLightLevel: metadataDict["maxFrameAverageLightLevel"] as? Float ?? maxLum * 0.4
                )
            }
        }
        
        return nil
    }
    
    private func generateProcessedMetadata(for mode: ExtendedHDRMode,
                                            timestamp: CMTime) -> ProcessedMetadata {
        guard let capabilities = displayCapabilities else {
            return ProcessedMetadata(
                hdr10PlusParams: nil,
                dolbyVisionParams: nil,
                selectedTrimPass: nil,
                timestamp: timestamp
            )
        }
        
        switch mode {
        case .hdr10Plus(let metadata):
            let params = hdr10PlusParser.generateDynamicToneMappingParams(
                for: metadata,
                displayCapabilities: capabilities
            )
            return ProcessedMetadata(
                hdr10PlusParams: params,
                dolbyVisionParams: nil,
                selectedTrimPass: nil,
                timestamp: timestamp
            )
            
        case .dolbyVision(let metadata):
            let trimPass = dolbyVisionParser.selectTrimPass(
                for: metadata,
                displayCapabilities: capabilities
            )
            let params = dolbyVisionParser.generateToneMappingParams(
                for: metadata,
                trimPass: trimPass,
                displayCapabilities: capabilities
            )
            return ProcessedMetadata(
                hdr10PlusParams: nil,
                dolbyVisionParams: params,
                selectedTrimPass: trimPass,
                timestamp: timestamp
            )
            
        default:
            return ProcessedMetadata(
                hdr10PlusParams: nil,
                dolbyVisionParams: nil,
                selectedTrimPass: nil,
                timestamp: timestamp
            )
        }
    }
    
    private func passthroughToExternalDisplays(_ mode: ExtendedHDRMode, timestamp: CMTime) {
        let passthroughMetadata: MetadataPassthroughManager.PassthroughMetadata
        
        switch mode {
        case .hdr10(let metadata):
            passthroughMetadata = MetadataPassthroughManager.PassthroughMetadata(
                hdr10Metadata: metadata,
                hdr10PlusMetadata: nil,
                dolbyVisionMetadata: nil,
                timestamp: timestamp
            )
        case .hdr10Plus(let metadata):
            passthroughMetadata = MetadataPassthroughManager.PassthroughMetadata(
                hdr10Metadata: nil,
                hdr10PlusMetadata: metadata,
                dolbyVisionMetadata: nil,
                timestamp: timestamp
            )
        case .dolbyVision(let metadata):
            passthroughMetadata = MetadataPassthroughManager.PassthroughMetadata(
                hdr10Metadata: nil,
                hdr10PlusMetadata: nil,
                dolbyVisionMetadata: metadata,
                timestamp: timestamp
            )
        default:
            return
        }
        
        passthroughManager.processMetadata(passthroughMetadata, for: nil)
    }
}

// MARK: - MetalRenderer Integration

extension HDRMetadataProcessor {
    
    func updateMetalRendererUniforms(_ renderer: MetalRenderer) {
        guard let capabilities = displayCapabilities else { return }
        
        switch currentHDRMode {
        case .hdr10Plus(let metadata):
            let params = hdr10PlusParser.generateDynamicToneMappingParams(
                for: metadata,
                displayCapabilities: capabilities
            )
            renderer.updateDynamicHDRParams(
                kneePoint: params.kneePoint,
                compressionRatio: params.compressionRatio,
                saturationScale: params.colorSaturationScale,
                brightnessAdjustment: params.brightnessAdjustment
            )
            
        case .dolbyVision(let metadata):
            if let trimPass = dolbyVisionParser.selectTrimPass(
                for: metadata,
                displayCapabilities: capabilities
            ) {
                let params = dolbyVisionParser.generateToneMappingParams(
                    for: metadata,
                    trimPass: trimPass,
                    displayCapabilities: capabilities
                )
                renderer.updateDynamicHDRParams(
                    kneePoint: params.luminanceScale,
                    compressionRatio: params.minLuminanceScale,
                    saturationScale: params.saturationScale,
                    brightnessAdjustment: params.brightnessAdjustment
                )
            }
            
        default:
            renderer.resetDynamicHDRParams()
        }
    }
}

// MARK: - Render Pass Encoder Integration (per-frame, frame-time based)

extension HDRMetadataProcessor {
    
    func applyMetadata(to renderPass: MTLRenderCommandEncoder, frameTime: TimeInterval) {
        let resolved = resolveParams(forFrameTime: frameTime)
        let interpolated = interpolateParams(resolved, frameTime: frameTime)
        
        var uniforms = buildHDRUniforms(from: interpolated)
        renderPass.setFragmentBytes(&uniforms,
                                    length: MemoryLayout<HDRUniforms>.size,
                                    index: 1)
        renderPass.setVertexBytes(&uniforms,
                                  length: MemoryLayout<HDRUniforms>.size,
                                  index: 1)
    }
    
    // MARK: - Parameter resolution
    
    func resolveParams(forFrameTime frameTime: TimeInterval) -> AppliedHDRParams {
        guard let capabilities = displayCapabilities else {
            return staticFallbackParams()
        }
        
        switch currentHDRMode {
        case .hdr10Plus:
            let timestamp = CMTime(seconds: frameTime, preferredTimescale: 600)
            if processingConfig.enableDynamicToneMapping,
               let processed = getProcessedMetadata(for: timestamp),
               let params = processed.hdr10PlusParams {
                return AppliedHDRParams(
                    kneePoint: params.kneePoint,
                    compressionRatio: params.compressionRatio,
                    saturationScale: params.colorSaturationScale,
                    brightnessAdjustment: params.brightnessAdjustment,
                    useDynamicMetadata: true,
                    isDolbyVision: false,
                    dvProfile: nil
                )
            }
            return staticFallbackParams()
            
        case .dolbyVision(let metadata):
            let trimPass = dolbyVisionParser.selectTrimPass(
                for: metadata,
                displayCapabilities: capabilities
            )
            let params = dolbyVisionParser.generateToneMappingParams(
                for: metadata,
                trimPass: trimPass,
                displayCapabilities: capabilities
            )
            if !capabilities.supportsEDR && processingConfig.fallbackToStaticHDR {
                return staticFallbackParams()
            }
            return AppliedHDRParams(
                kneePoint: params.luminanceScale,
                compressionRatio: params.minLuminanceScale,
                saturationScale: params.saturationScale,
                brightnessAdjustment: params.brightnessAdjustment,
                useDynamicMetadata: true,
                isDolbyVision: true,
                dvProfile: metadata.profile
            )
            
        case .hdr10(let hdr10):
            let displayMax = capabilities.maxEDRLuminance
            let knee = min(hdr10.maxFrameAverageLightLevel / max(displayMax, 1.0), 1.0)
            return AppliedHDRParams(
                kneePoint: knee,
                compressionRatio: 1.0,
                saturationScale: 1.0,
                brightnessAdjustment: 0.0,
                useDynamicMetadata: false,
                isDolbyVision: false,
                dvProfile: nil
            )
            
        case .hlg:
            return AppliedHDRParams(
                kneePoint: 0.5,
                compressionRatio: 1.0,
                saturationScale: 1.0,
                brightnessAdjustment: 0.0,
                useDynamicMetadata: false,
                isDolbyVision: false,
                dvProfile: nil
            )
            
        case .sdr:
            return AppliedHDRParams(
                kneePoint: 0.0,
                compressionRatio: 1.0,
                saturationScale: 1.0,
                brightnessAdjustment: 0.0,
                useDynamicMetadata: false,
                isDolbyVision: false,
                dvProfile: nil
            )
        }
    }
    
    private func staticFallbackParams() -> AppliedHDRParams {
        return AppliedHDRParams(
            kneePoint: 0.5,
            compressionRatio: 1.0,
            saturationScale: 1.0,
            brightnessAdjustment: 0.0,
            useDynamicMetadata: false,
            isDolbyVision: false,
            dvProfile: nil
        )
    }
    
    // MARK: - Transition smoothing
    
    private func interpolateParams(_ target: AppliedHDRParams, frameTime: TimeInterval) -> AppliedHDRParams {
        if !paramsEqual(lastAppliedParams, target) {
            transitionStartTime = frameTime
            targetParams = target
        }
        
        guard let last = lastAppliedParams, let to = targetParams else {
            lastAppliedParams = target
            return target
        }
        
        let elapsed = max(frameTime - transitionStartTime, 0)
        let t: Float = transitionDuration > 0
            ? min(max(Float(elapsed / transitionDuration), 0), 1)
            : 1.0
        let eased = t * t * (3 - 2 * t)
        
        let blended = AppliedHDRParams(
            kneePoint: lerp(last.kneePoint, to.kneePoint, eased),
            compressionRatio: lerp(last.compressionRatio, to.compressionRatio, eased),
            saturationScale: lerp(last.saturationScale, to.saturationScale, eased),
            brightnessAdjustment: lerp(last.brightnessAdjustment, to.brightnessAdjustment, eased),
            useDynamicMetadata: eased >= 0.5 ? to.useDynamicMetadata : last.useDynamicMetadata,
            isDolbyVision: eased >= 0.5 ? to.isDolbyVision : last.isDolbyVision,
            dvProfile: eased >= 0.5 ? to.dvProfile : last.dvProfile
        )
        
        if t >= 1.0 {
            lastAppliedParams = to
        }
        return blended
    }
    
    private func paramsEqual(_ lhs: AppliedHDRParams?, _ rhs: AppliedHDRParams) -> Bool {
        guard let lhs = lhs else { return false }
        return lhs.kneePoint == rhs.kneePoint &&
            lhs.compressionRatio == rhs.compressionRatio &&
            lhs.saturationScale == rhs.saturationScale &&
            lhs.brightnessAdjustment == rhs.brightnessAdjustment &&
            lhs.useDynamicMetadata == rhs.useDynamicMetadata &&
            lhs.isDolbyVision == rhs.isDolbyVision &&
            lhs.dvProfile == rhs.dvProfile
    }
    
    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + (b - a) * t
    }
    
    // MARK: - Uniform construction
    
    private func buildHDRUniforms(from params: AppliedHDRParams) -> HDRUniforms {
        let caps = displayCapabilities
        let modeRaw: UInt32
        switch currentHDRMode {
        case .sdr: modeRaw = HDRModeRaw.sdr.rawValue
        case .hdr10: modeRaw = HDRModeRaw.hdr10.rawValue
        case .hlg: modeRaw = HDRModeRaw.hlg.rawValue
        case .hdr10Plus, .dolbyVision: modeRaw = HDRModeRaw.hdr10.rawValue
        }
        
        return HDRUniforms(
            hdrMode: modeRaw,
            isHDRDisplay: caps?.supportsEDR == true ? 1 : 0,
            colorMatrix: iccMatrixForCurrentGamut(),
            maxLuminance: caps?.maxEDRLuminance ?? processingConfig.targetLuminance,
            minLuminance: 0.001,
            maxContentLightLevel: caps?.maxEDRLuminance ?? processingConfig.targetLuminance,
            maxFrameAverageLightLevel: (caps?.maxEDRLuminance ?? processingConfig.targetLuminance) * 0.4,
            kneePoint: params.kneePoint,
            compressionRatio: params.compressionRatio,
            saturationScale: params.saturationScale,
            brightnessAdjustment: params.brightnessAdjustment,
            useDynamicMetadata: params.useDynamicMetadata ? 1 : 0
        )
    }
    
    private func iccMatrixForCurrentGamut() -> simd_float3x3 {
        guard let gamut = displayCapabilities?.colorGamut else {
            return ICCProfile.sRGB.matrix
        }
        switch gamut {
        case .bt2020:
            return simd_float3x3(
                SIMD3<Float>(1.7166512, -0.3556708, -0.2533663),
                SIMD3<Float>(-0.6666844, 1.6164812, 0.0157685),
                SIMD3<Float>(0.0176399, -0.0427706, 0.9421031)
            )
        case .displayP3:
            return simd_float3x3(
                SIMD3<Float>(0.8224622, 0.1775380, 0.0000000),
                SIMD3<Float>(0.0331942, 0.9668058, 0.0000000),
                SIMD3<Float>(0.0170813, 0.0723974, 0.9105213)
            )
        case .srgb:
            return ICCProfile.sRGB.matrix
        }
    }
}
