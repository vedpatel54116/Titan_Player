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

    // Performance-driven resolution cap (set by PerformanceOptimizer via RenderAdapter).
    private(set) var currentResolutionCap: ResolutionCap = .original

    // Dynamic metadata support
    private var dynamicKneePoint: Float = 0.0
    private var dynamicCompressionRatio: Float = 1.0
    private var dynamicSaturationScale: Float = 1.0
    private var dynamicBrightnessAdjustment: Float = 0.0
    private var useDynamicMetadata: Bool = false
    
    // HDR mode tracking for telemetry
    private var hdrModeStartTime: Date?
    private var lastReportedHDRMode: TelemetryHDRMode?
    
    private var hdrUniformsBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    
    private var toneMappedTexture: MTLTexture?
    
    private var subtitleTexture: MTLTexture?
    private var subtitlePipelineState: MTLRenderPipelineState?
    
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    
    private let displayDetector = DisplayCapabilityDetector()
    
    private var displayTargets: [String: DisplayRenderTarget] = [:]
    
    private let vertexData: [Float] = [
        -1.0, -1.0, 0.0, 1.0,
         1.0, -1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 0.0,
    ]
    
    weak var delegate: MetalRendererDelegate?
    weak var frameStore: FrameStore?
    
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
        reportFinalHDRMode()
    }
    
    private func reportFinalHDRMode() {
        if let startTime = hdrModeStartTime, let lastMode = lastReportedHDRMode {
            let duration = Date().timeIntervalSince(startTime)
            if duration > 0.1 {
                Task { @MainActor in
                    TelemetryManager.shared.record(.hdrModeUsed(mode: lastMode, duration: duration))
                }
            }
        }
        hdrModeStartTime = nil
        lastReportedHDRMode = nil
    }

    func updateDisplayCapabilitiesSynchronously(for screen: NSScreen) {
        displayCapabilities = displayDetector.detectCapabilities(for: screen)
        iccProfile = displayDetector.detectICCProfile(for: screen)
        if let caps = displayCapabilities {
            delegate?.renderer(self, didUpdateDisplayCapabilities: caps)
        }
    }

    func updateDisplayCapabilitiesAsynchronously(for screen: NSScreen) {
        DispatchQueue.main.async { [weak self] in
            self?.updateDisplayCapabilitiesSynchronously(for: screen)
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
        
        let subtitleFunction = library.makeFunction(name: "subtitleFragment")
        let subtitleDescriptor = MTLRenderPipelineDescriptor()
        subtitleDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        subtitleDescriptor.fragmentFunction = subtitleFunction
        subtitleDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        subtitlePipelineState = try? device.makeRenderPipelineState(descriptor: subtitleDescriptor)
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
        // Report previous HDR mode duration if we were tracking one
        if let startTime = hdrModeStartTime, let lastMode = lastReportedHDRMode {
            let duration = Date().timeIntervalSince(startTime)
            if duration > 0.1 { // Only report if > 100ms
                Task { @MainActor in
                    TelemetryManager.shared.record(.hdrModeUsed(mode: lastMode, duration: duration))
                }
            }
        }
        
        currentHDRMode = mode
        delegate?.renderer(self, didDetectHDRMode: mode)
        
        // Start tracking new mode
        switch mode {
        case .sdr:
            hdrModeStartTime = nil
            lastReportedHDRMode = nil
        case .hdr10:
            hdrModeStartTime = Date()
            lastReportedHDRMode = .hdr10
        case .hlg:
            hdrModeStartTime = Date()
            lastReportedHDRMode = .hlghdr
        }
    }

    func setResolutionCap(_ cap: ResolutionCap) {
        currentResolutionCap = cap
        // v1: store cap only — materializing the intermediate downscaled
        // texture happens during the next `draw(in:)` call. If the cap is
        // `.original`, the pipeline falls back to native dimensions.
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
    
    // MARK: - Multi-Display Target Support
    
    func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile) {
        guard displayTargets[stableID] == nil else { return }
        
        let uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<HDRUniforms>.size,
            options: .storageModeShared
        )!
        
        var uniforms = HDRUniforms(
            hdrMode: 0,
            isHDRDisplay: capabilities.supportsEDR ? 1 : 0,
            colorMatrix: iccProfile.matrix,
            maxLuminance: capabilities.maxEDRLuminance,
            minLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0,
            kneePoint: 0,
            compressionRatio: 1,
            saturationScale: 1,
            brightnessAdjustment: 0,
            useDynamicMetadata: 0
        )
        memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<HDRUniforms>.size)
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = device.makeDefaultLibrary()?.makeFunction(name: "vertexShader")
        pipelineDescriptor.fragmentFunction = device.makeDefaultLibrary()?.makeFunction(name: "fragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        
        let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        
        let target = DisplayRenderTarget(
            stableID: stableID,
            layer: layer,
            capabilities: capabilities,
            iccProfile: iccProfile,
            hdrUniformsBuffer: uniformsBuffer,
            toneMappedTexture: nil,
            renderPipelineState: pipelineState
        )
        displayTargets[stableID] = target
    }
    
    func removeDisplayTarget(stableID: String) {
        displayTargets.removeValue(forKey: stableID)
    }
    
    func updateDisplayCapabilities(for stableID: String, capabilities: DisplayCapabilities, iccProfile: ICCProfile) {
        guard var target = displayTargets[stableID] else { return }
        target.capabilities = capabilities
        target.iccProfile = iccProfile
        
        var uniforms = HDRUniforms(
            hdrMode: 0,
            isHDRDisplay: capabilities.supportsEDR ? 1 : 0,
            colorMatrix: iccProfile.matrix,
            maxLuminance: capabilities.maxEDRLuminance,
            minLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0,
            kneePoint: 0,
            compressionRatio: 1,
            saturationScale: 1,
            brightnessAdjustment: 0,
            useDynamicMetadata: 0
        )
        memcpy(target.hdrUniformsBuffer.contents(), &uniforms, MemoryLayout<HDRUniforms>.size)
        displayTargets[stableID] = target
    }
    
    private func renderTarget(
        _ target: DisplayRenderTarget,
        inputTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        var target = target
        let width = target.layer.drawableSize.width > 0 ? Int(target.layer.drawableSize.width) : inputTexture.width
        let height = target.layer.drawableSize.height > 0 ? Int(target.layer.drawableSize.height) : inputTexture.height
        
        if target.toneMappedTexture?.width != width || target.toneMappedTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: width, height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            target.toneMappedTexture = device.makeTexture(descriptor: descriptor)
        }
        
        guard let outputTexture = target.toneMappedTexture,
              let toneMappingPipeline = toneMappingPipeline else { return }
        
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            computeEncoder.setComputePipelineState(toneMappingPipeline)
            computeEncoder.setTexture(inputTexture, index: 0)
            computeEncoder.setTexture(outputTexture, index: 1)
            computeEncoder.setBuffer(target.hdrUniformsBuffer, offset: 0, index: 0)
            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
            computeEncoder.endEncoding()
        }
        
        guard let drawable = target.layer.nextDrawable(),
              let pipelineState = target.renderPipelineState,
              let vertexBuffer = vertexBuffer else { return }
        
        let renderDescriptor = MTLRenderPassDescriptor()
        renderDescriptor.colorAttachments[0].texture = drawable.texture
        renderDescriptor.colorAttachments[0].loadAction = .clear
        renderDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderDescriptor.colorAttachments[0].storeAction = .store
        
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDescriptor) {
            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(outputTexture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
        }
        
        commandBuffer.present(drawable)
    }
    
    func updateSubtitleBitmap(_ bitmap: SubtitleBitmap?) {
        guard let bitmap = bitmap else {
            subtitleTexture = nil
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: bitmap.pixelFormat,
            width: bitmap.width,
            height: bitmap.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        texture.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: bitmap.width, height: bitmap.height, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: bitmap.pixels.baseAddress!,
            bytesPerRow: bitmap.bytesPerRow
        )

        subtitleTexture = texture
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
        
        if let subtitleTexture = subtitleTexture,
           let subtitlePipelineState = subtitlePipelineState,
           let outputTexture = toneMappedTexture {
            let subtitleDescriptor = createRenderPassDescriptor(drawable: drawable)
            if let subtitleEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: subtitleDescriptor) {
                subtitleEncoder.setRenderPipelineState(subtitlePipelineState)
                subtitleEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                subtitleEncoder.setFragmentTexture(outputTexture, index: 0)
                subtitleEncoder.setFragmentTexture(subtitleTexture, index: 1)
                subtitleEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                subtitleEncoder.endEncoding()
            }
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
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPipeline = renderPipeline,
              let vertexBuffer = vertexBuffer else { return }

        inFlightSemaphore.wait()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        if let frame = pendingFrame {
            if let inputTexture = createTexture(from: frame.pixelBuffer) {
                updateToneMappedTexture(width: inputTexture.width, height: inputTexture.height)
                updateHDRUniforms(metadata: nil)

                if let outputTexture = toneMappedTexture,
                   let toneMappingPipeline = toneMappingPipeline,
                   let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
                    computeEncoder.setComputePipelineState(toneMappingPipeline)
                    computeEncoder.setTexture(inputTexture, index: 0)
                    computeEncoder.setTexture(outputTexture, index: 1)
                    computeEncoder.setBuffer(hdrUniformsBuffer, offset: 0, index: 0)
                    let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
                    let gridSize = MTLSize(width: inputTexture.width,
                                           height: inputTexture.height, depth: 1)
                    computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
                    computeEncoder.endEncoding()
                }
            }
            pendingFrame = nil
        }

        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: createRenderPassDescriptor(drawable: drawable)),
           let outputTexture = toneMappedTexture {
            renderEncoder.setRenderPipelineState(renderPipeline)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(outputTexture, index: 0)
            renderEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()

            if let store = frameStore {
                store.update(outputTexture)
            }
        }

        if let subtitleTexture = subtitleTexture,
           let subtitlePipelineState = subtitlePipelineState,
           let outputTexture = toneMappedTexture {
            let subtitleDescriptor = createRenderPassDescriptor(drawable: drawable)
            if let subtitleEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: subtitleDescriptor) {
                subtitleEncoder.setRenderPipelineState(subtitlePipelineState)
                subtitleEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                subtitleEncoder.setFragmentTexture(outputTexture, index: 0)
                subtitleEncoder.setFragmentTexture(subtitleTexture, index: 1)
                subtitleEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                subtitleEncoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

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
