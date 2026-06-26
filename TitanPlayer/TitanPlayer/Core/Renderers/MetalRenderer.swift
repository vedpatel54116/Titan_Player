import Metal
import MetalKit
import CoreVideo
import simd

class MetalRenderer: NSObject, MTKViewDelegate, FrameRendering {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    private var toneMappingPipeline: MTLComputePipelineState?
    private var renderPipeline: MTLRenderPipelineState?
    
    private var currentHDRMode: HDRMode = .sdr
    private var displayCapabilities: DisplayCapabilities?
    private var iccProfile: ICCProfile = .sRGB
    
    // Dynamic metadata support
    private var dynamicKneePoint: Float = 0.0
    private var dynamicCompressionRatio: Float = 1.0
    private var dynamicSaturationScale: Float = 1.0
    private var dynamicBrightnessAdjustment: Float = 0.0
    private var useDynamicMetadata: Bool = false
    
    private var hdrUniformsBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    
    private var toneMappedTexture: MTLTexture?
    
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    
    private let displayDetector = DisplayCapabilityDetector()
    
    private let vertexData: [Float] = [
        -1.0, -1.0, 0.0, 1.0,
         1.0, -1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 0.0,
    ]
    
    weak var delegate: MetalRendererDelegate?
    
    override init() {
        let device = MTLCreateSystemDefaultDevice()!
        let commandQueue = device.makeCommandQueue()!
        self.device = device
        self.commandQueue = commandQueue
        super.init()
        setupPipelines()
        setupBuffers()
        if let screen = NSScreen.main {
            updateDisplayCapabilitiesSynchronously(for: screen)
        }
    }

    func attach(to view: MTKView) {
        view.delegate = self
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
    }

    func detach() {
    }

    func updateDisplayCapabilitiesSynchronously(for screen: NSScreen) {
        displayCapabilities = displayDetector.detectCapabilities(for: screen)
        iccProfile = displayDetector.detectICCProfile(for: screen)
        if let caps = displayCapabilities {
            delegate?.renderer(self, didUpdateDisplayCapabilities: caps)
        }
    }
    
    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }
        
        if let toneMappingFunction = library.makeFunction(name: "hdrToneMapping") {
            toneMappingPipeline = try? device.makeComputePipelineState(function: toneMappingFunction)
        }
        
        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        
        renderPipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    private func setupBuffers() {
        vertexBuffer = device.makeBuffer(
            bytes: vertexData,
            length: vertexData.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
        
        hdrUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<HDRUniforms>.size,
            options: .storageModeShared
        )
        
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<Uniforms>.size,
            options: .storageModeShared
        )
    }
    
        
    func updateDisplayCapabilities(for screen: NSScreen) {
        displayCapabilities = displayDetector.detectCapabilities(for: screen)
        iccProfile = displayDetector.detectICCProfile(for: screen)
        
        if let caps = displayCapabilities {
            delegate?.renderer(self, didUpdateDisplayCapabilities: caps)
        }
    }
    
    func updateHDRMode(_ mode: HDRMode) {
        currentHDRMode = mode
        delegate?.renderer(self, didDetectHDRMode: mode)
    }
    
    func updateDynamicHDRParams(kneePoint: Float,
                                 compressionRatio: Float,
                                 saturationScale: Float,
                                 brightnessAdjustment: Float) {
        dynamicKneePoint = kneePoint
        dynamicCompressionRatio = compressionRatio
        dynamicSaturationScale = saturationScale
        dynamicBrightnessAdjustment = brightnessAdjustment
        useDynamicMetadata = true
    }
    
    func resetDynamicHDRParams() {
        dynamicKneePoint = 0.0
        dynamicCompressionRatio = 1.0
        dynamicSaturationScale = 1.0
        dynamicBrightnessAdjustment = 0.0
        useDynamicMetadata = false
    }
    
    func render(pixelBuffer: CVPixelBuffer, 
                metadata: HDRMetadata?,
                to drawable: CAMetalDrawable) {
        inFlightSemaphore.wait()
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }
        
        guard let inputTexture = createTexture(from: pixelBuffer) else {
            commandBuffer.commit()
            return
        }
        
        updateToneMappedTexture(width: inputTexture.width, height: inputTexture.height)
        
        guard let outputTexture = toneMappedTexture else {
            commandBuffer.commit()
            return
        }
        
        updateHDRUniforms(metadata: metadata)
        
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
           let toneMappingPipeline = toneMappingPipeline {
            computeEncoder.setComputePipelineState(toneMappingPipeline)
            computeEncoder.setTexture(inputTexture, index: 0)
            computeEncoder.setTexture(outputTexture, index: 1)
            computeEncoder.setBuffer(hdrUniformsBuffer, offset: 0, index: 0)
            
            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
            computeEncoder.endEncoding()
        }
        
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: createRenderPassDescriptor(drawable: drawable)),
           let renderPipeline = renderPipeline,
           let vertexBuffer = vertexBuffer {
            renderEncoder.setRenderPipelineState(renderPipeline)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(outputTexture, index: 0)
            renderEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .managed
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                 size: MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
        
        return texture
    }
    
    private func updateToneMappedTexture(width: Int, height: Int) {
        guard toneMappedTexture?.width != width || toneMappedTexture?.height != height else {
            return
        }
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        
        toneMappedTexture = device.makeTexture(descriptor: descriptor)
    }
    
    private func updateHDRUniforms(metadata: HDRMetadata?) {
        guard let buffer = hdrUniformsBuffer else { return }
        
        var uniforms = HDRUniforms(
            hdrMode: 0,
            isHDRDisplay: displayCapabilities?.supportsEDR == true ? 1 : 0,
            colorMatrix: iccProfile.matrix,
            maxLuminance: 1000.0,
            minLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0,
            kneePoint: dynamicKneePoint,
            compressionRatio: dynamicCompressionRatio,
            saturationScale: dynamicSaturationScale,
            brightnessAdjustment: dynamicBrightnessAdjustment,
            useDynamicMetadata: useDynamicMetadata ? 1 : 0
        )
        
        if let metadata = metadata {
            switch currentHDRMode {
            case .hdr10(let hdr10Meta):
                uniforms.hdrMode = 1
                uniforms.maxLuminance = hdr10Meta.maxDisplayLuminance
                uniforms.minLuminance = hdr10Meta.minDisplayLuminance
                uniforms.maxContentLightLevel = hdr10Meta.maxContentLightLevel
                uniforms.maxFrameAverageLightLevel = hdr10Meta.maxFrameAverageLightLevel
            case .hlg:
                uniforms.hdrMode = 2
            case .sdr:
                uniforms.hdrMode = 0
            }
        }
        
        memcpy(buffer.contents(), &uniforms, MemoryLayout<HDRUniforms>.size)
    }
    
    private func createRenderPassDescriptor(drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    func draw(in view: MTKView) {}

    // MARK: - FrameRendering

    func render(_ frame: VideoFrame) async throws {
        // Store the most recent frame; drawable-driven submission happens
        // in draw(in:) once the next CAMetalDrawable is available.
        pendingFrame = frame
    }

    private var pendingFrame: VideoFrame?

    func handleHDR(_ metadata: HDRMetadata) {
        switch metadata.type {
        case .hdr10:
            let hdr10 = HDR10Metadata(
                displayPrimaries: (
                    red: SIMD2<Float>(0.708, 0.292),
                    green: SIMD2<Float>(0.170, 0.797),
                    blue: SIMD2<Float>(0.131, 0.046)
                ),
                whitePoint: SIMD2<Float>(0.3127, 0.3290),
                maxDisplayLuminance: metadata.maxLuminance,
                minDisplayLuminance: metadata.minLuminance,
                maxContentLightLevel: metadata.maxLuminance,
                maxFrameAverageLightLevel: 400
            )
            updateHDRMode(.hdr10(hdr10))
        case .hlg:
            updateHDRMode(.hlg)
        case .dolbyVision:
            updateHDRMode(.sdr)
        }
    }
}

protocol MetalRendererDelegate: AnyObject {
    func renderer(_ renderer: MetalRenderer, didDetectHDRMode mode: HDRMode)
    func renderer(_ renderer: MetalRenderer, didUpdateDisplayCapabilities caps: DisplayCapabilities)
}


extension MetalRenderer {
    static func make() throws -> MetalRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw RendererError.deviceUnavailable
        }
        return MetalRenderer()
    }
}
