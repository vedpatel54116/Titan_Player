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
        let gamut = detectGamut(for: screen)
        return ICCProfile.profile(for: gamut)
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
    
    func configureEDR(for metalView: MTKView, capabilities: DisplayCapabilities) {
        guard capabilities.supportsEDR else { return }
        
        metalView.colorPixelFormat = .rgba16Float
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
        }
    }
}
