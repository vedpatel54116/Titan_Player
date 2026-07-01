import Metal
import MetalKit

struct DisplayRenderTarget {
    let stableID: String
    let layer: CAMetalLayer
    var capabilities: DisplayCapabilities
    var iccProfile: ICCProfile
    var hdrUniformsBuffer: MTLBuffer
    var toneMappedTexture: MTLTexture?
    var renderPipelineState: MTLRenderPipelineState?
}
