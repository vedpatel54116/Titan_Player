import Metal
import MetalKit
import CoreVideo
import simd
import os.log
import AVFoundation

class MetalRenderer: NSObject, MTKViewDelegate, FrameRendering {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    private var ycbcrPipeline: MTLComputePipelineState?
    private var toneMappingPipeline: MTLComputePipelineState?
    private var renderPipeline: MTLRenderPipelineState?
    
    private var textureCache: CVMetalTextureCache?
    private var pixelBufferPool: CVPixelBufferPool?
    private var nv12PixelBufferPool: CVPixelBufferPool?
    
    private var currentHDRMode: HDRMode = .sdr
    private var displayCapabilities: DisplayCapabilities?
    private var iccProfile: ICCProfile = .sRGB
    
    private let hdrMetadataProcessor = HDRMetadataProcessor()
    private let logger = Logger(subsystem: "com.titanplayer", category: "MetalRenderer")

    // Performance-driven resolution cap (set by PerformanceOptimizer via RenderAdapter).
    private(set) var currentResolutionCap: ResolutionCap = .original

    // Dynamic metadata support
    private var dynamicKneePoint: Float = 0.0
    private var dynamicCompressionRatio: Float = 1.0
    private var dynamicSaturationScale: Float = 1.0
    private var dynamicBrightnessAdjustment: Float = 0.0
    private var useDynamicMetadata: Bool = false
    
    private var hdrModeStartTime: Date?
    private var lastReportedHDRMode: TelemetryHDRMode?

    // Debug state — exposed for the debug overlay
    var lastPixelFormat: OSType = 0
    var debugPipelineState: String = "idle"
    var pendingFrameCount: Int { pendingFrame != nil ? 1 : 0 }
    
    private var hdrUniformsBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    
    private var toneMappedTexture: MTLTexture?
    
    private var subtitleTexture: MTLTexture?
    private var subtitlePipelineState: MTLRenderPipelineState?
    
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    
    private let displayDetector = DisplayCapabilityDetector()
    
    // Fallback state — set when Metal pipeline setup fails so the
    // renderer can hand control back to AVPlayerLayer-based rendering
    // instead of showing a black screen or crashing.
    private(set) var fallbackActive = false
    var fallbackLayer: AVPlayerLayer?
    
    private var displayTargets: [String: DisplayRenderTarget] = [:]
    
    private var currentDrawableSize: CGSize = .zero
    private var currentVideoSize: CGSize = .zero
    
    private let vertexData: [Float] = [
        -1.0, -1.0, 0.0, 1.0,
         1.0, -1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 0.0,
    ]
    
    weak var delegate: MetalRendererDelegate?
    weak var frameStore: FrameStore?
    private weak var mtkView: MTKView?
    
    private override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("MetalRenderer: MTLCreateSystemDefaultDevice() returned nil — Metal is unavailable")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("MetalRenderer: device.makeCommandQueue() returned nil")
        }
        self.device = device
        self.commandQueue = commandQueue
        super.init()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache

        setupPipelines()
        setupBuffers()
        if let screen = NSScreen.main {
            updateDisplayCapabilitiesSynchronously(for: screen)
        }
    }

    /// Returns `true` if the Metal device is available and `MetalRenderer`
    /// can be safely instantiated. Call before `MetalRenderer()` to avoid
    /// crashing on machines without GPU support.
    static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    func attach(to view: MTKView) {
        self.mtkView = view
        view.delegate = self
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60

        // Configure EDR for HDR content
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: "kCGColorSpaceITUR_2020_PQ_EOTF" as CFString)
        }
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
            hdrMetadataProcessor.updateDisplayCapabilities(caps)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.delegate?.renderer(self, didUpdateDisplayCapabilities: caps)
            }
        }
    }

    func updateDisplayCapabilitiesAsynchronously(for screen: NSScreen) {
        DispatchQueue.main.async { [weak self] in
            self?.updateDisplayCapabilitiesSynchronously(for: screen)
        }
    }
    
    private func setupPipelines() {
        guard let library = MetalShaders.loadLibrary(device: device) else {
            logger.error("MetalShaders.loadLibrary returned nil — activating fallback rendering")
            fallbackActive = true
            return
        }
        
        if let ycbcrFunction = library.makeFunction(name: "ycbcr_to_rgb") {
            ycbcrPipeline = try? device.makeComputePipelineState(function: ycbcrFunction)
        }
        
        if let toneMappingFunction = library.makeFunction(name: "hdr_tone_mapping") {
            toneMappingPipeline = try? device.makeComputePipelineState(function: toneMappingFunction)
        }
        
        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "video_fragment_shader")
        
        guard vertexFunction != nil, fragmentFunction != nil else {
            logger.error("Required shader functions not found — activating fallback rendering")
            fallbackActive = true
            return
        }
        
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
        
        fallbackActive = renderPipeline == nil || toneMappingPipeline == nil
        if fallbackActive {
            logger.warning("Some pipelines failed to compile — Metal rendering degraded")
        }
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

        // The fragment shader reads this buffer every frame. It must always
        // hold valid values — Metal zero-initializes new buffers, which would
        // leave `iccMatrix` as the zero matrix and blank the output to black.
        updatePictureUniforms()
    }

    /// Populates `uniformsBuffer` with neutral picture controls and an identity
    /// ICC matrix. The HDR tone-mapping pass already performs the gamut/color
    /// conversion, so the fragment pass is a pass-through here. Call this again
    /// if the user adjusts brightness/contrast/saturation/hue at runtime.
    private func updatePictureUniforms() {
        guard let buffer = uniformsBuffer else { return }

        var uniforms = Uniforms(
            brightness: 0.0,
            contrast: 1.0,
            saturation: 1.0,
            hue: 0.0,
            iccMatrix: matrix_identity_float3x3
        )
        memcpy(buffer.contents(), &uniforms, MemoryLayout<Uniforms>.size)
    }
    
        
    func updateDisplayCapabilities(for screen: NSScreen) {
        displayCapabilities = displayDetector.detectCapabilities(for: screen)
        iccProfile = displayDetector.detectICCProfile(for: screen)
        
        if let caps = displayCapabilities {
            hdrMetadataProcessor.updateDisplayCapabilities(caps)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.delegate?.renderer(self, didUpdateDisplayCapabilities: caps)
            }
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
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.renderer(self, didDetectHDRMode: mode)
        }
        
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
            lastReportedHDRMode = .hlg
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
        logger.info("Tone mapping update — knee: \(String(format: "%.3f", kneePoint)), compression: \(String(format: "%.3f", compressionRatio)), saturation: \(String(format: "%.3f", saturationScale)), brightness: \(String(format: "%.3f", brightnessAdjustment))")
    }
    
    func resetDynamicHDRParams() {
        dynamicKneePoint = 0.0
        dynamicCompressionRatio = 1.0
        dynamicSaturationScale = 1.0
        dynamicBrightnessAdjustment = 0.0
        useDynamicMetadata = false
    }

    private func applyMetadataUpdate(_ update: HDRMetadataProcessor.MetadataUpdate) {
        switch update.mode {
        case .hdr10(let meta):
            updateHDRMode(.hdr10(meta))
        case .hlg:
            updateHDRMode(.hlg)
        case .sdr:
            updateHDRMode(.sdr)
        case .hdr10Plus(let meta):
            updateHDRMode(.hdr10(meta.toHDR10Metadata()))
        case .dolbyVision:
            let hdr10 = HDR10Metadata(
                displayPrimaries: (red: SIMD2<Float>(0.708, 0.292), green: SIMD2<Float>(0.170, 0.797), blue: SIMD2<Float>(0.131, 0.046)),
                whitePoint: SIMD2<Float>(0.3127, 0.3290),
                maxDisplayLuminance: 1000.0,
                minDisplayLuminance: 0.001,
                maxContentLightLevel: 1000.0,
                maxFrameAverageLightLevel: 400.0
            )
            updateHDRMode(.hdr10(hdr10))
        }
        hdrMetadataProcessor.updateMetalRendererUniforms(self)
    }
    
    // MARK: - Multi-Display Target Support
    
    func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile) {
        guard displayTargets[stableID] == nil else { return }
        
        guard let uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<HDRUniforms>.size,
            options: .storageModeShared
        ) else {
            logger.error("Failed to allocate HDR uniforms buffer for display target \(stableID, privacy: .public)")
            return
        }
        
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
        pipelineDescriptor.fragmentFunction = device.makeDefaultLibrary()?.makeFunction(name: "video_fragment_shader")
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

        guard let baseAddress = bitmap.pixels.baseAddress else {
            logger.error("SubtitleBitmap pixel buffer has nil base address")
            return
        }
        texture.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: bitmap.width, height: bitmap.height, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: baseAddress,
            bytesPerRow: bitmap.bytesPerRow
        )

        subtitleTexture = texture
    }
    
    func render(pixelBuffer: CVPixelBuffer, 
                metadata: HDRMetadata?,
                to drawable: CAMetalDrawable) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        lastPixelFormat = pixelFormat
        debugPipelineState = "decoding"
        logger.debug("render(pixelBuffer:to:) format: \(self.fourCharCodeToString(pixelFormat), privacy: .public)")

        inFlightSemaphore.wait()
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }
        
        guard let textures = createTextures(from: pixelBuffer),
              let ycbcrPipeline = ycbcrPipeline else {
            logger.warning("Failed to create textures from pixel buffer, clearing to black")
            let desc = createRenderPassDescriptor(drawable: drawable)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) {
                enc.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        
        logger.debug("Texture created from frame: \(textures.y.width, privacy: .public)x\(textures.y.height, privacy: .public)")
        
        let rgbTexture = createRGBTexture(
            width: textures.y.width,
            height: textures.y.height
        )
        
        guard let rgbTexture = rgbTexture else {
            logger.warning("Failed to create RGB texture, presenting black")
            let desc = createRenderPassDescriptor(drawable: drawable)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) {
                enc.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            var ycbcrUniforms = YCbCrUniforms(
                yScale: 1.0,
                yOffset: -16.0 / 255.0,
                cbcrScale: 1.0,
                cbcrOffset: -128.0 / 255.0,
                isHDR: 0
            )
            
            computeEncoder.setComputePipelineState(ycbcrPipeline)
            computeEncoder.setTexture(textures.y, index: 0)
            computeEncoder.setTexture(textures.cbcr, index: 1)
            computeEncoder.setTexture(rgbTexture, index: 2)
            computeEncoder.setBytes(&ycbcrUniforms,
                                   length: MemoryLayout<YCbCrUniforms>.size,
                                   index: 0)
            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: rgbTexture.width,
                                  height: rgbTexture.height, depth: 1)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
            computeEncoder.endEncoding()
        }
        
        updateToneMappedTexture(width: rgbTexture.width, height: rgbTexture.height)
        
        guard let outputTexture = toneMappedTexture else {
            logger.warning("Tone mapped texture nil, presenting black")
            let desc = createRenderPassDescriptor(drawable: drawable)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) {
                enc.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        
        updateHDRUniforms()
        
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
           let toneMappingPipeline = toneMappingPipeline {
            computeEncoder.setComputePipelineState(toneMappingPipeline)
            computeEncoder.setTexture(rgbTexture, index: 0)
            computeEncoder.setTexture(outputTexture, index: 1)
            computeEncoder.setBuffer(hdrUniformsBuffer, offset: 0, index: 0)
            
            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: rgbTexture.width, height: rgbTexture.height, depth: 1)
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
           let subtitlePipelineState = subtitlePipelineState {
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
    
    private func createTextures(from pixelBuffer: CVPixelBuffer) -> (y: MTLTexture, cbcr: MTLTexture)? {
        guard let cache = textureCache else { return nil }

        guard let compatibleBuffer = ensureCompatiblePixelBuffer(pixelBuffer) else {
            return nil
        }

        var yTextureRef: CVMetalTexture?
        var cbcrTextureRef: CVMetalTexture?
        
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            compatibleBuffer,
            nil,
            .r8Unorm,
            CVPixelBufferGetWidthOfPlane(compatibleBuffer, 0),
            CVPixelBufferGetHeightOfPlane(compatibleBuffer, 0),
            0,
            &yTextureRef
        )
        
        let cbcrStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            compatibleBuffer,
            nil,
            .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(compatibleBuffer, 1),
            CVPixelBufferGetHeightOfPlane(compatibleBuffer, 1),
            1,
            &cbcrTextureRef
        )
        
        guard yStatus == kCVReturnSuccess,
              cbcrStatus == kCVReturnSuccess,
              let yRef = yTextureRef,
              let cbcrRef = cbcrTextureRef,
              let yTex = CVMetalTextureGetTexture(yRef),
              let cbcrTex = CVMetalTextureGetTexture(cbcrRef) else {
            return nil
        }
        
        return (y: yTex, cbcr: cbcrTex)
    }

    private func ensureCompatiblePixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let targetFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        if format == targetFormat {
            return pixelBuffer
        }

        logger.warning("Pixel buffer format \(self.fourCharCodeToString(format)) is not NV12, converting")

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if nv12PixelBufferPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: targetFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            nv12PixelBufferPool = pool
        }

        guard let pool = nv12PixelBufferPool else {
            logger.error("Failed to create NV12 pixel buffer pool")
            return nil
        }

        var convertedBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &convertedBuffer)

        guard let output = convertedBuffer else {
            logger.error("Failed to allocate NV12 pixel buffer from pool")
            return nil
        }

        // Convert using vImage / Accelerate
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])

        if CVPixelBufferIsPlanar(pixelBuffer) {
            // Source is planar — copy planes directly if possible, else use CIImage
            let ciInput = CIImage(cvPixelBuffer: pixelBuffer)
            let ciContext = CIContext()
            ciContext.render(ciInput, to: output)
        } else {
            // Source is packed (e.g. BGRA) — use CIImage conversion
            let ciInput = CIImage(cvPixelBuffer: pixelBuffer)
            let ciContext = CIContext()
            ciContext.render(ciInput, to: output)
        }

        CVPixelBufferUnlockBaseAddress(output, [])
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        return output
    }

    private func fourCharCodeToString(_ code: OSType) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
    }
    
    private func createRGBTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
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
    
    private func updateHDRUniforms() {
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
        
        // Drive HDR tone-mapping mode from the decoder/metadata state rather
        // than from a transient `metadata` argument. `currentHDRMode` is kept
        // up to date by `applyMetadataUpdate`, so it is the correct source of
        // truth on both the live MTKView path and the legacy render path.
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
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        currentDrawableSize = size
        updateAspectFitVertices()
    }
    
    private func updateAspectFitVertices() {
        guard let vertexBuffer = vertexBuffer,
              currentVideoSize.width > 0, currentVideoSize.height > 0,
              currentDrawableSize.width > 0, currentDrawableSize.height > 0 else { return }
        
        let videoAspect = Float(currentVideoSize.width) / Float(currentVideoSize.height)
        let drawableAspect = Float(currentDrawableSize.width) / Float(currentDrawableSize.height)
        
        var scaleX: Float = 1.0
        var scaleY: Float = 1.0
        
        if videoAspect > drawableAspect {
            scaleY = drawableAspect / videoAspect
        } else {
            scaleX = videoAspect / drawableAspect
        }
        
        let vertexData: [Float] = [
            -scaleX, -scaleY, 0.0, 1.0,
             scaleX, -scaleY, 1.0, 1.0,
            -scaleX,  scaleY, 0.0, 0.0,
             scaleX,  scaleY, 1.0, 0.0,
        ]
        
        memcpy(vertexBuffer.contents(), vertexData, vertexData.count * MemoryLayout<Float>.size)
    }
    
    func draw(in view: MTKView) {
        if fallbackActive {
            // Fallback: clear to black — the app should degrade to
            // AVPlayerLayer-based rendering via compatibility mode.
            guard let drawable = view.currentDrawable else { return }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture = drawable.texture
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: desc) {
                enc.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        
        guard let drawable = view.currentDrawable,
              let renderPipeline = renderPipeline,
              let vertexBuffer = vertexBuffer else { return }

        if currentDrawableSize == .zero {
            currentDrawableSize = view.drawableSize
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        inFlightSemaphore.wait()
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }

        if let frame = pendingFrame {
            if let textures = createTextures(from: frame.pixelBuffer),
               let ycbcrPipeline = ycbcrPipeline {
                currentVideoSize = CGSize(
                    width: textures.y.width,
                    height: textures.y.height
                )
                updateAspectFitVertices()
                
                let rgbTexture = createRGBTexture(
                    width: textures.y.width,
                    height: textures.y.height
                )
                
                if let rgbTexture = rgbTexture,
                   let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
                    var ycbcrUniforms = YCbCrUniforms(
                        yScale: 1.0,
                        yOffset: -16.0 / 255.0,
                        cbcrScale: 1.0,
                        cbcrOffset: -128.0 / 255.0,
                        isHDR: 0
                    )
                    
                    computeEncoder.setComputePipelineState(ycbcrPipeline)
                    computeEncoder.setTexture(textures.y, index: 0)
                    computeEncoder.setTexture(textures.cbcr, index: 1)
                    computeEncoder.setTexture(rgbTexture, index: 2)
                    computeEncoder.setBytes(&ycbcrUniforms,
                                           length: MemoryLayout<YCbCrUniforms>.size,
                                           index: 0)
                    let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
                    let gridSize = MTLSize(width: rgbTexture.width,
                                          height: rgbTexture.height, depth: 1)
                    computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
                    computeEncoder.endEncoding()
                    
                    updateToneMappedTexture(width: rgbTexture.width, height: rgbTexture.height)

                    if let sampleBuffer = frame.sampleBuffer,
                       let update = hdrMetadataProcessor.processMetadata(from: sampleBuffer) {
                        applyMetadataUpdate(update)
                    }
                    updateHDRUniforms()
                    
                    if let outputTexture = toneMappedTexture,
                       let toneMappingPipeline = toneMappingPipeline,
                       let toneEncoder = commandBuffer.makeComputeCommandEncoder() {
                        toneEncoder.setComputePipelineState(toneMappingPipeline)
                        toneEncoder.setTexture(rgbTexture, index: 0)
                        toneEncoder.setTexture(outputTexture, index: 1)
                        toneEncoder.setBuffer(hdrUniformsBuffer, offset: 0, index: 0)
                        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
                        let gSize = MTLSize(width: rgbTexture.width,
                                           height: rgbTexture.height, depth: 1)
                        toneEncoder.dispatchThreads(gSize, threadsPerThreadgroup: tgSize)
                        toneEncoder.endEncoding()
                    }
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
        } else {
            // No frame available — clear to black
            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: createRenderPassDescriptor(drawable: drawable)) {
                renderEncoder.endEncoding()
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
        logger.debug("Received video frame for rendering")
        pendingFrame = frame
        mtkView?.setNeedsDisplay(mtkView?.bounds ?? .zero)
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
            let dvMeta = HDR10Metadata(
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
            updateHDRMode(.hdr10(dvMeta))
        }
    }
}

@MainActor
protocol MetalRendererDelegate: AnyObject {
    func renderer(_ renderer: MetalRenderer, didDetectHDRMode mode: HDRMode)
    func renderer(_ renderer: MetalRenderer, didUpdateDisplayCapabilities caps: DisplayCapabilities)
}


extension MetalRenderer {
    static func make() throws -> MetalRenderer {
        guard isAvailable else {
            throw RendererError.deviceUnavailable
        }
        return MetalRenderer()
    }
}
