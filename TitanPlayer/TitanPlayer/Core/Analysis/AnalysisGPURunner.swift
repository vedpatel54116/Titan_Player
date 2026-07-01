import Foundation
import Metal
import simd

/// Set of optional video-analyzer kernels. The runner uses this to decide
/// which pipelines must be ready before dispatching.
struct AnalysisFlags: OptionSet {
    let rawValue: Int
    static let histogram   = AnalysisFlags(rawValue: 1 << 0)
    static let vectorscope = AnalysisFlags(rawValue: 1 << 1)
    static let waveform    = AnalysisFlags(rawValue: 1 << 2)
    static let colorPicker = AnalysisFlags(rawValue: 1 << 3)
}

/// Owns its own `MTLDevice`/`MTLCommandQueue` (separate from `MetalRenderer`'s
/// in-flight semaphore) and dispatches the 4 analysis kernels against the
/// post-tone-mapped texture exposed by `FrameStore`.
///
/// **Optimization**: Analysis kernels run asynchronously on a dedicated command
/// queue with lower priority. The input texture is copied to a private buffer
/// first to avoid contention with the render pipeline.
final class AnalysisGPURunner {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let semaphore = DispatchSemaphore(value: 1)

    private let library: MTLLibrary?
    private var histogramPipeline: MTLComputePipelineState?
    private var vectorscopePipeline: MTLComputePipelineState?
    private var waveformPipeline: MTLComputePipelineState?
    private var colorPickerPipeline: MTLComputePipelineState?

    /// Reusable staging texture for async copies (avoids alloc per frame).
    private var stagingTexture: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue() ?? device.makeCommandQueue(maxCommandBufferCount: 16)!
        self.queue.label = "com.titanplayer.analysis.gpu"
        self.library = device.makeDefaultLibrary()
        loadPipelines()
    }

    private func loadPipelines() {
        guard let library = library else { return }
        if let f = library.makeFunction(name: "kernelHistogram") {
            histogramPipeline = try? device.makeComputePipelineState(function: f)
        }
        if let f = library.makeFunction(name: "kernelVectorscope") {
            vectorscopePipeline = try? device.makeComputePipelineState(function: f)
        }
        if let f = library.makeFunction(name: "kernelWaveform") {
            waveformPipeline = try? device.makeComputePipelineState(function: f)
        }
        if let f = library.makeFunction(name: "kernelColorPicker") {
            colorPickerPipeline = try? device.makeComputePipelineState(function: f)
        }
    }

    func isReady(for flags: AnalysisFlags) -> Bool {
        if flags.contains(.histogram)   && histogramPipeline   == nil { return false }
        if flags.contains(.vectorscope) && vectorscopePipeline == nil { return false }
        if flags.contains(.waveform)    && waveformPipeline    == nil { return false }
        if flags.contains(.colorPicker) && colorPickerPipeline == nil { return false }
        return true
    }

    // MARK: - Private helpers

    /// Ensure `stagingTexture` matches the given dimensions and format.
    private func ensureStagingTexture(width: Int, height: Int, format: MTLPixelFormat) {
        if let existing = stagingTexture,
           existing.width == width,
           existing.height == height,
           existing.pixelFormat == format {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        stagingTexture = device.makeTexture(descriptor: desc)
    }

    /// Copy `source` into a private staging texture via a blit encoder.
    /// Returns the staging texture (valid only within the same command buffer).
    private func copyToStaging(source: MTLTexture,
                               commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        ensureStagingTexture(width: source.width,
                             height: source.height,
                             format: source.pixelFormat)
        guard let dest = stagingTexture else { return nil }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: source,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: source.width,
                                          height: source.height, depth: 1),
                      to: dest,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.synchronize(resource: dest)
            blit.endEncoding()
        }
        return dest
    }

    // MARK: - Async Histogram

    /// Dispatch `kernelHistogram` asynchronously. Calls `completion` on a
    /// private queue when the GPU has finished writing to the output buffer.
    func runHistogramAsync(texture: MTLTexture,
                           completion: @escaping (HistogramData?) -> Void) {
        guard let pipeline = histogramPipeline else {
            completion(nil)
            return
        }

        let bins = 256
        let totalBins = bins * 4
        let bytes = totalBins * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            completion(nil)
            return
        }
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: totalBins)
        for i in 0..<totalBins { ptr[i] = 0 }

        guard let commandBuffer = queue.makeCommandBuffer() else {
            completion(nil)
            return
        }
        commandBuffer.label = "analysis.histogram"

        // Copy texture to staging to avoid blocking the render pipeline.
        guard let srcTexture = copyToStaging(source: texture,
                                             commandBuffer: commandBuffer) else {
            completion(nil)
            return
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(srcTexture, index: 0)
            enc.setBuffer(buffer, offset: 0,                      index: 0)
            enc.setBuffer(buffer, offset: bins  * MemoryLayout<UInt32>.stride, index: 1)
            enc.setBuffer(buffer, offset: bins  * 2 * MemoryLayout<UInt32>.stride, index: 2)
            enc.setBuffer(buffer, offset: bins  * 3 * MemoryLayout<UInt32>.stride, index: 3)
            let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: texture.width, height: texture.height, depth: 1)
            enc.dispatchThreads(grid, threadsPerThreadgroup: threadgroup)
            enc.endEncoding()
        }

        commandBuffer.addCompletedHandler { _ in
            let r = Array(UnsafeBufferPointer(start: ptr,                     count: bins))
            let g = Array(UnsafeBufferPointer(start: ptr.advanced(by: bins),   count: bins))
            let b = Array(UnsafeBufferPointer(start: ptr.advanced(by: bins*2), count: bins))
            let y = Array(UnsafeBufferPointer(start: ptr.advanced(by: bins*3), count: bins))
            completion(HistogramData(redBins: r, greenBins: g, blueBins: b, lumaBins: y))
        }
        commandBuffer.commit()
    }

    // MARK: - Async Vectorscope

    func runVectorscopeAsync(texture: MTLTexture,
                             completion: @escaping (VectorscopeData?) -> Void) {
        guard let pipeline = vectorscopePipeline else {
            completion(nil)
            return
        }

        let side = 256
        let total = side * side
        let bytes = total * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            completion(nil)
            return
        }
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: total)
        for i in 0..<total { ptr[i] = 0 }

        guard let commandBuffer = queue.makeCommandBuffer() else {
            completion(nil)
            return
        }
        commandBuffer.label = "analysis.vectorscope"

        guard let srcTexture = copyToStaging(source: texture,
                                             commandBuffer: commandBuffer) else {
            completion(nil)
            return
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(srcTexture, index: 0)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.dispatchThreads(
                MTLSize(width: texture.width, height: texture.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }

        commandBuffer.addCompletedHandler { _ in
            let grid = Array(UnsafeBufferPointer(start: ptr, count: total))
            completion(VectorscopeData(grid: grid, gridSize: side))
        }
        commandBuffer.commit()
    }

    // MARK: - Async Waveform

    func runWaveformAsync(texture: MTLTexture,
                          completion: @escaping (WaveformData?) -> Void) {
        guard let pipeline = waveformPipeline else {
            completion(nil)
            return
        }

        let cols = 1024
        let buckets = 8
        let channels = 4
        let stride = cols * buckets
        let bytes = stride * channels * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            completion(nil)
            return
        }
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: stride * channels)
        for i in 0..<(stride * channels) { ptr[i] = 0 }

        guard let commandBuffer = queue.makeCommandBuffer() else {
            completion(nil)
            return
        }
        commandBuffer.label = "analysis.waveform"

        guard let srcTexture = copyToStaging(source: texture,
                                             commandBuffer: commandBuffer) else {
            completion(nil)
            return
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(srcTexture, index: 0)
            enc.setBuffer(buffer, offset: 0,                                 index: 0)
            enc.setBuffer(buffer, offset: stride  * MemoryLayout<UInt32>.stride, index: 1)
            enc.setBuffer(buffer, offset: stride  * 2 * MemoryLayout<UInt32>.stride, index: 2)
            enc.setBuffer(buffer, offset: stride  * 3 * MemoryLayout<UInt32>.stride, index: 3)
            enc.dispatchThreads(
                MTLSize(width: texture.width, height: texture.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }

        commandBuffer.addCompletedHandler { _ in
            var flat = [Float](repeating: 0, count: stride * channels)
            for i in 0..<(stride * channels) { flat[i] = Float(ptr[i]) }
            completion(WaveformData(columnLuminance: flat))
        }
        commandBuffer.commit()
    }

    // MARK: - Async Color picker (single pixel)

    func samplePixelAsync(texture: MTLTexture,
                          col: Int,
                          row: Int,
                          completion: @escaping (SIMD4<Float>) -> Void) {
        guard let pipeline = colorPickerPipeline else {
            completion(.zero)
            return
        }

        let outBytes = MemoryLayout<SIMD4<Float>>.stride
        guard let out = device.makeBuffer(length: outBytes, options: .storageModeShared) else {
            completion(.zero)
            return
        }
        var args = ColorPickerArgs(coord: SIMD2<UInt32>(UInt32(col), UInt32(row)))
        guard let argsBuf = device.makeBuffer(bytes: &args,
                                             length: MemoryLayout<ColorPickerArgs>.size,
                                             options: .storageModeShared) else {
            completion(.zero)
            return
        }

        guard let commandBuffer = queue.makeCommandBuffer() else {
            completion(.zero)
            return
        }
        commandBuffer.label = "analysis.colorPicker"

        guard let srcTexture = copyToStaging(source: texture,
                                             commandBuffer: commandBuffer) else {
            completion(.zero)
            return
        }

        if let enc = commandBuffer.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            enc.setTexture(srcTexture, index: 0)
            enc.setBuffer(out, offset: 0, index: 0)
            enc.setBuffer(argsBuf, offset: 0, index: 1)
            enc.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            enc.endEncoding()
        }

        commandBuffer.addCompletedHandler { _ in
            let p = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 1)
            completion(p[0])
        }
        commandBuffer.commit()
    }

    // MARK: - Synchronous wrappers (call from background queue only)

    /// Synchronous histogram – blocks until GPU completes.
    /// Prefer `runHistogramAsync` to avoid blocking the render pipeline.
    func runHistogram(texture: MTLTexture) -> HistogramData? {
        semaphore.wait()
        defer { semaphore.signal() }

        let bins = 256
        let totalBins = bins * 4
        let bytes = totalBins * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: totalBins)
        for i in 0..<totalBins { ptr[i] = 0 }

        let comm = queue.makeCommandBuffer()
        let enc = comm?.makeComputeCommandEncoder()
        enc?.setComputePipelineState(histogramPipeline!)
        enc?.setTexture(texture, index: 0)
        enc?.setBuffer(buffer, offset: 0,                      index: 0)
        enc?.setBuffer(buffer, offset: bins  * MemoryLayout<UInt32>.stride, index: 1)
        enc?.setBuffer(buffer, offset: bins  * 2 * MemoryLayout<UInt32>.stride, index: 2)
        enc?.setBuffer(buffer, offset: bins  * 3 * MemoryLayout<UInt32>.stride, index: 3)
        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: texture.width, height: texture.height, depth: 1)
        enc?.dispatchThreads(grid, threadsPerThreadgroup: threadgroup)
        enc?.endEncoding()
        comm?.commit()
        comm?.waitUntilCompleted()

        let r = Array(UnsafeBufferPointer(start: ptr,                     count: bins))
        let g = Array(UnsafeBufferPointer(start: ptr.advanced(by: bins),   count: bins))
        let b = Array(UnsafeBufferPointer(start: ptr.advanced(by: bins*2), count: bins))
        let y = Array(UnsafeBufferPointer(start: ptr.advanced(by: bins*3), count: bins))
        return HistogramData(redBins: r, greenBins: g, blueBins: b, lumaBins: y)
    }

    /// Synchronous vectorscope – blocks until GPU completes.
    func runVectorscope(texture: MTLTexture) -> VectorscopeData? {
        guard let pipeline = vectorscopePipeline else { return nil }
        semaphore.wait()
        defer { semaphore.signal() }

        let side = 256
        let total = side * side
        let bytes = total * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: total)
        for i in 0..<total { ptr[i] = 0 }

        let comm = queue.makeCommandBuffer()
        let enc = comm?.makeComputeCommandEncoder()
        enc?.setComputePipelineState(pipeline)
        enc?.setTexture(texture, index: 0)
        enc?.setBuffer(buffer, offset: 0, index: 0)
        enc?.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc?.endEncoding()
        comm?.commit()
        comm?.waitUntilCompleted()

        let grid = Array(UnsafeBufferPointer(start: ptr, count: total))
        return VectorscopeData(grid: grid, gridSize: side)
    }

    /// Synchronous waveform – blocks until GPU completes.
    func runWaveform(texture: MTLTexture) -> WaveformData? {
        guard let pipeline = waveformPipeline else { return nil }
        semaphore.wait()
        defer { semaphore.signal() }

        let cols = 1024
        let buckets = 8
        let channels = 4
        let stride = cols * buckets
        let bytes = stride * channels * MemoryLayout<UInt32>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: stride * channels)
        for i in 0..<(stride * channels) { ptr[i] = 0 }

        let comm = queue.makeCommandBuffer()
        let enc = comm?.makeComputeCommandEncoder()
        enc?.setComputePipelineState(pipeline)
        enc?.setTexture(texture, index: 0)
        enc?.setBuffer(buffer, offset: 0,                                 index: 0)
        enc?.setBuffer(buffer, offset: stride  * MemoryLayout<UInt32>.stride, index: 1)
        enc?.setBuffer(buffer, offset: stride  * 2 * MemoryLayout<UInt32>.stride, index: 2)
        enc?.setBuffer(buffer, offset: stride  * 3 * MemoryLayout<UInt32>.stride, index: 3)
        enc?.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc?.endEncoding()
        comm?.commit()
        comm?.waitUntilCompleted()

        var flat = [Float](repeating: 0, count: stride * channels)
        for i in 0..<(stride * channels) { flat[i] = Float(ptr[i]) }
        return WaveformData(columnLuminance: flat)
    }

    /// Synchronous color picker – blocks until GPU completes.
    func samplePixel(texture: MTLTexture, col: Int, row: Int) -> SIMD4<Float> {
        guard let pipeline = colorPickerPipeline else { return SIMD4<Float>(0, 0, 0, 0) }
        semaphore.wait()
        defer { semaphore.signal() }

        let outBytes = MemoryLayout<SIMD4<Float>>.stride
        guard let out = device.makeBuffer(length: outBytes, options: .storageModeShared) else { return .zero }
        var args = ColorPickerArgs(coord: SIMD2<UInt32>(UInt32(col), UInt32(row)))
        guard let argsBuf = device.makeBuffer(bytes: &args,
                                             length: MemoryLayout<ColorPickerArgs>.size,
                                             options: .storageModeShared) else { return .zero }

        let comm = queue.makeCommandBuffer()
        let enc = comm?.makeComputeCommandEncoder()
        enc?.setComputePipelineState(pipeline)
        enc?.setTexture(texture, index: 0)
        enc?.setBuffer(out, offset: 0, index: 0)
        enc?.setBuffer(argsBuf, offset: 0, index: 1)
        enc?.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc?.endEncoding()
        comm?.commit()
        comm?.waitUntilCompleted()

        let p = out.contents().bindMemory(to: SIMD4<Float>.self, capacity: 1)
        return p[0]
    }
}

/// Mirrors `Analysis.metal::ColorPickerArgs`. Keep the field order in sync.
private struct ColorPickerArgs {
    var coord: SIMD2<UInt32>
}
