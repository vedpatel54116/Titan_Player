import Foundation
import AppKit
import Metal

typealias VideoRenderer = FrameRendering

protocol FrameRendering: AnyObject {
    func render(_ frame: VideoFrame) async throws
    func handleHDR(_ metadata: HDRMetadata)
    func updateDisplayCapabilities(for screen: NSScreen)
    func resetDynamicHDRParams()

    func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile)
    func removeDisplayTarget(stableID: String)
}

extension FrameRendering {
    func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile) {}
    func removeDisplayTarget(stableID: String) {}
}

enum RendererError: Error, LocalizedError {
    case notAttached
    case deviceUnavailable
    case pipelineCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAttached:
            return "Renderer is not attached to a Metal view."
        case .deviceUnavailable:
            return "Metal device is unavailable on this system."
        case .pipelineCreationFailed(let s):
            return "Failed to create Metal pipeline: \(s)"
        }
    }
}
