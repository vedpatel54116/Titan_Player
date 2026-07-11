import Foundation
import CoreGraphics
import CoreMedia
import AppKit
import os

class MetadataPassthroughManager {
    
    // MARK: - Properties
    
    private var externalDisplays: [CGDirectDisplayID: ExternalDisplayInfo] = [:]
    private var passthroughEnabled: Bool = true
    private var currentHDRMode: ExtendedHDRMode = .sdr
    
    // MARK: - Types
    
    struct ExternalDisplayInfo {
        let displayID: CGDirectDisplayID
        let supportsHDR: Bool
        let supportsDolbyVision: Bool
        let maxLuminance: Float
        let colorGamut: ColorGamut
        let lastMetadataTimestamp: Date
    }
    
    struct PassthroughMetadata {
        let hdr10Metadata: HDR10Metadata?
        let hdr10PlusMetadata: HDR10PlusMetadata?
        let dolbyVisionMetadata: DolbyVisionMetadata?
        let timestamp: CMTime
    }
    
    // MARK: - Initialization
    
    init() {
        detectExternalDisplays()
    }
    
    // MARK: - Public Methods
    
    func enablePassthrough(_ enabled: Bool) {
        passthroughEnabled = enabled
    }
    
    func updateHDRMode(_ mode: ExtendedHDRMode) {
        currentHDRMode = mode
        passthroughMetadataToExternalDisplays()
    }
    
    func processMetadata(_ metadata: PassthroughMetadata, for displayID: CGDirectDisplayID?) {
        guard passthroughEnabled else { return }
        
        if let displayID = displayID {
            passthroughToSpecificDisplay(metadata, displayID: displayID)
        } else {
            passthroughToAllDisplays(metadata)
        }
    }
    
    func getExternalDisplays() -> [ExternalDisplayInfo] {
        return Array(externalDisplays.values)
    }
    
    func supportsDolbyVisionOnDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        return externalDisplays[displayID]?.supportsDolbyVision ?? false
    }
    
    // MARK: - Private Methods
    
    private func detectExternalDisplays() {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            
            if screenNumber == CGMainDisplayID() {
                continue
            }
            
            let capabilities = detectDisplayCapabilities(for: screen)
            
            let displayInfo = ExternalDisplayInfo(
                displayID: screenNumber,
                supportsHDR: capabilities.supportsHDR,
                supportsDolbyVision: Self.inferDolbyVisionSupport(from: capabilities),
                maxLuminance: capabilities.maxEDRLuminance,
                colorGamut: capabilities.colorGamut,
                lastMetadataTimestamp: Date()
            )
            
            externalDisplays[screenNumber] = displayInfo
        }
    }
    
    private func detectDisplayCapabilities(for screen: NSScreen) -> DisplayCapabilities {
        let detector = DisplayCapabilityDetector()
        return detector.detectCapabilities(for: screen)
    }

    /// Dolby Vision requires an HDR10/PQ-capable pipeline. We can't read EDID
    /// here, so we conservatively infer DV support only for displays that
    /// advertise EDR *and* a BT.2020 gamut. Plain HDR10/P3 displays must not be
    /// reported as DV-capable, otherwise DV metadata would be passed through to
    /// displays that cannot consume it (and the DV→HDR10 fallback would never
    /// trigger).
    private static func inferDolbyVisionSupport(from capabilities: DisplayCapabilities) -> Bool {
        capabilities.supportsEDR && capabilities.colorGamut == .bt2020
    }
    
    private func passthroughToAllDisplays(_ metadata: PassthroughMetadata) {
        // Iterate over a snapshot of the keys so we don't mutate the dictionary
        // while it is being enumerated.
        let displayIDs = Array(externalDisplays.keys)
        for displayID in displayIDs {
            passthroughToSpecificDisplay(metadata, displayID: displayID)
        }
    }
    
    private func passthroughToSpecificDisplay(_ metadata: PassthroughMetadata, displayID: CGDirectDisplayID) {
        guard let displayInfo = externalDisplays[displayID] else { return }
        
        let adaptedMetadata = adaptMetadataForDisplay(metadata, displayInfo: displayInfo)
        
        sendMetadataToDisplay(adaptedMetadata, displayID: displayID)
        
        externalDisplays[displayID] = ExternalDisplayInfo(
            displayID: displayID,
            supportsHDR: displayInfo.supportsHDR,
            supportsDolbyVision: displayInfo.supportsDolbyVision,
            maxLuminance: displayInfo.maxLuminance,
            colorGamut: displayInfo.colorGamut,
            lastMetadataTimestamp: Date()
        )
    }
    
    private func adaptMetadataForDisplay(_ metadata: PassthroughMetadata,
                                          displayInfo: ExternalDisplayInfo) -> PassthroughMetadata {
        if !displayInfo.supportsDolbyVision && metadata.dolbyVisionMetadata != nil {
            return PassthroughMetadata(
                hdr10Metadata: metadata.hdr10Metadata ?? createFallbackHDR10Metadata(),
                hdr10PlusMetadata: nil,
                dolbyVisionMetadata: nil,
                timestamp: metadata.timestamp
            )
        }
        
        var adaptedHDR10 = metadata.hdr10Metadata
        if let hdr10 = adaptedHDR10 {
            let clampedMaxLum = min(hdr10.maxDisplayLuminance, displayInfo.maxLuminance)
            adaptedHDR10 = HDR10Metadata(
                displayPrimaries: hdr10.displayPrimaries,
                whitePoint: hdr10.whitePoint,
                maxDisplayLuminance: clampedMaxLum,
                minDisplayLuminance: hdr10.minDisplayLuminance,
                maxContentLightLevel: min(hdr10.maxContentLightLevel, displayInfo.maxLuminance),
                maxFrameAverageLightLevel: min(hdr10.maxFrameAverageLightLevel, displayInfo.maxLuminance)
            )
        }
        
        return PassthroughMetadata(
            hdr10Metadata: adaptedHDR10,
            hdr10PlusMetadata: metadata.hdr10PlusMetadata,
            dolbyVisionMetadata: metadata.dolbyVisionMetadata,
            timestamp: metadata.timestamp
        )
    }
    
    private func createFallbackHDR10Metadata() -> HDR10Metadata {
        return HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: 1000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )
    }
    
    private func sendMetadataToDisplay(_ metadata: PassthroughMetadata, displayID: CGDirectDisplayID) {
        let logger = os.Logger(subsystem: "com.titanplayer", category: "MetadataPassthrough")
        logger.info("Passthrough metadata to display \(displayID):")
        if let hdr10 = metadata.hdr10Metadata {
            logger.info("  HDR10: maxLum=\(hdr10.maxDisplayLuminance), MaxCLL=\(hdr10.maxContentLightLevel)")
        }
        if let hdr10Plus = metadata.hdr10PlusMetadata {
            logger.info("  HDR10+: kneePoint=\(hdr10Plus.kneePointX), anchors=\(hdr10Plus.numBezierCurveAnchors)")
        }
        if let dv = metadata.dolbyVisionMetadata {
            logger.info("  DolbyVision: profile=\(dv.profile.rawValue)")
        }
    }
    
    private func passthroughMetadataToExternalDisplays() {
        let metadata = createMetadataFromCurrentMode()
        passthroughToAllDisplays(metadata)
    }
    
    private func createMetadataFromCurrentMode() -> PassthroughMetadata {
        switch currentHDRMode {
        case .sdr:
            return PassthroughMetadata(hdr10Metadata: nil, hdr10PlusMetadata: nil, dolbyVisionMetadata: nil, timestamp: CMTime.zero)
        case .hdr10(let metadata):
            return PassthroughMetadata(hdr10Metadata: metadata, hdr10PlusMetadata: nil, dolbyVisionMetadata: nil, timestamp: CMTime.zero)
        case .hdr10Plus(let metadata):
            return PassthroughMetadata(hdr10Metadata: nil, hdr10PlusMetadata: metadata, dolbyVisionMetadata: nil, timestamp: CMTime.zero)
        case .dolbyVision(let metadata):
            return PassthroughMetadata(hdr10Metadata: nil, hdr10PlusMetadata: nil, dolbyVisionMetadata: metadata, timestamp: CMTime.zero)
        case .hlg:
            return PassthroughMetadata(hdr10Metadata: nil, hdr10PlusMetadata: nil, dolbyVisionMetadata: nil, timestamp: CMTime.zero)
        }
    }
}
