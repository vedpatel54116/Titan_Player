import AppKit
import CoreGraphics
import MetalKit
import simd

class DisplayCapabilityDetector {
    func detectCapabilities(for screen: NSScreen) -> DisplayCapabilities {
        let supportsEDR = screen.maximumExtendedDynamicRangeColorComponentValue > 1.0
        let maxEDRLuminance = Float(screen.maximumExtendedDynamicRangeColorComponentValue) * 80.0
        let gamut = detectGamut(for: screen)
        let supportsHDR = supportsEDR || gamut == .bt2020
        
        return DisplayCapabilities(
            supportsHDR: supportsHDR,
            supportsEDR: supportsEDR,
            maxEDRLuminance: maxEDRLuminance,
            colorGamut: gamut
        )
    }
    
    func detectICCProfile(for screen: NSScreen) -> ICCProfile {
        guard let colorSpace = screen.colorSpace else {
            return .sRGB
        }
        
        let gamut = detectGamut(for: screen)
        let matrix = extractMatrix(from: colorSpace)
        
        return ICCProfile(gamut: gamut, matrix: matrix)
    }
    
    private func detectGamut(for screen: NSScreen) -> ColorGamut {
        guard let colorSpace = screen.colorSpace else {
            return .srgb
        }
        
        let name = colorSpace.localizedName ?? ""
        
        if name.contains("2020") || name.contains("BT.2020") {
            return .bt2020
        } else if name.contains("P3") || name.contains("Display P3") {
            return .displayP3
        } else {
            return .srgb
        }
    }
    
    private func extractMatrix(from colorSpace: NSColorSpace) -> simd_float3x3 {
        let gamut = detectGamutFromColorSpace(colorSpace)
        
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
    
    private func detectGamutFromColorSpace(_ colorSpace: NSColorSpace) -> ColorGamut {
        let name = colorSpace.localizedName ?? ""
        
        if name.contains("2020") || name.contains("BT.2020") {
            return .bt2020
        } else if name.contains("P3") || name.contains("Display P3") {
            return .displayP3
        } else {
            return .srgb
        }
    }
    
    func configureEDR(for metalView: MTKView, capabilities: DisplayCapabilities) {
        guard capabilities.supportsEDR else { return }
        
        metalView.colorPixelFormat = .rgba16Float
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
        }
    }
}
