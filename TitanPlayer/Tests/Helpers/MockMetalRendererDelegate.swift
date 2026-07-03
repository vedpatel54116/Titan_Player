import AppKit
@testable import TitanPlayer

@MainActor
final class MockMetalRendererDelegate: MetalRendererDelegate {
    private(set) var detectedModes: [HDRMode] = []
    private(set) var capabilitiesUpdates: [DisplayCapabilities] = []

    func renderer(_ renderer: MetalRenderer, didDetectHDRMode mode: HDRMode) {
        detectedModes.append(mode)
    }

    func renderer(_ renderer: MetalRenderer, didUpdateDisplayCapabilities caps: DisplayCapabilities) {
        capabilitiesUpdates.append(caps)
    }
}
