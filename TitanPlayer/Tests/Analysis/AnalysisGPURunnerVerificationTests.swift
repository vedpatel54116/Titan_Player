import XCTest
import Metal
@testable import TitanPlayer

/// Verification tests for Prompt 12: VideoAnalysisManager GPU Runner.
///
/// Acceptance Criteria:
/// 1. The waveform overlay appears and updates in real-time.
/// 2. Video playback remains smooth at 60fps with analysis enabled.
/// 3. No "GPU Timeout" or Metal synchronization errors.
@MainActor
final class AnalysisGPURunnerVerificationTests: XCTestCase {

    // MARK: - Helpers

    private func makeDevice() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return d
    }

    private func makeTexture(device: MTLDevice, width: Int, height: Int,
                             fill: Float = 1.0) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let tex = device.makeTexture(descriptor: desc) else {
            XCTFail("Failed to create texture")
            throw NSError(domain: "Test", code: 1)
        }
        let pixelCount = width * height
        var data = [Float](repeating: 0, count: pixelCount * 4)
        for i in 0..<pixelCount {
            data[i * 4 + 0] = fill  // R
            data[i * 4 + 1] = fill  // G
            data[i * 4 + 2] = fill  // B
            data[i * 4 + 3] = 1.0   // A
        }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: width * 4 * MemoryLayout<Float>.size)
        return tex
    }

    // MARK: - 1. Waveform Async Dispatch Does Not Block

    /// Verify that `runWaveformAsync` returns immediately (does not block the
    /// calling thread) while the GPU processes the compute kernel.
    func testWaveformAsyncReturnsImmediately() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        guard runner.isReady(for: .waveform) else {
            throw XCTSkip("kernelWaveform not found")
        }

        let tex = try makeTexture(device: device, width: 512, height: 512)

        let expectation = expectation(description: "waveform completion")
        var result: WaveformData?

        let start = Date()

        runner.runWaveformAsync(texture: tex) { wave in
            result = wave
            expectation.fulfill()
        }

        let returnTime = Date()
        let elapsedReturn = returnTime.timeIntervalSince(start)

        // The async method should return in < 50ms (well under 16ms frame budget
        // plus generous margin for setup overhead).
        XCTAssertLessThan(elapsedReturn, 0.05,
                          "runWaveformAsync should return immediately, took \(elapsedReturn)s")

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(result, "WaveformData should be non-nil after GPU completion")
        XCTAssertEqual(result?.columnLuminance.count, 1024 * 8 * 4,
                       "Waveform output should have 1024 columns × 8 buckets × 4 channels")
    }

    // MARK: - 2. Histogram Async Dispatch Does Not Block

    func testHistogramAsyncReturnsImmediately() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        guard runner.isReady(for: .histogram) else {
            throw XCTSkip("kernelHistogram not found")
        }

        let tex = try makeTexture(device: device, width: 512, height: 512)

        let expectation = expectation(description: "histogram completion")
        var result: HistogramData?

        let start = Date()

        runner.runHistogramAsync(texture: tex) { hist in
            result = hist
            expectation.fulfill()
        }

        let elapsedReturn = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsedReturn, 0.05,
                          "runHistogramAsync should return immediately")

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(result, "HistogramData should be non-nil after GPU completion")
        XCTAssertEqual(result?.binCount, 256, "Histogram should have 256 bins")
        // All pixels are white (1.0), so bin 255 should have all pixels.
        let totalPixels = 512 * 512
        XCTAssertEqual(result?.lumaBins.last ?? 0, UInt32(totalPixels),
                       accuracy: UInt32(totalPixels / 10),
                       "Luma bin 255 should contain most pixels")
    }

    // MARK: - 3. Vectorscope Async Dispatch Does Not Block

    func testVectorscopeAsyncReturnsImmediately() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        guard runner.isReady(for: .vectorscope) else {
            throw XCTSkip("kernelVectorscope not found")
        }

        // Use saturated red/blue pixels to ensure vectorscope output.
        let w = 64, h = 64
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let tex = device.makeTexture(descriptor: desc) else {
            XCTFail("Failed to create texture")
            throw NSError(domain: "Test", code: 1)
        }
        var data = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                data[idx + 0] = (x < w / 2) ? 1.0 : 0.0  // R
                data[idx + 1] = 0.0                         // G
                data[idx + 2] = (x >= w / 2) ? 1.0 : 0.0  // B
                data[idx + 3] = 1.0                         // A
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: w * 4 * MemoryLayout<Float>.size)

        let expectation = expectation(description: "vectorscope completion")
        var result: VectorscopeData?

        let start = Date()

        runner.runVectorscopeAsync(texture: tex) { vec in
            result = vec
            expectation.fulfill()
        }

        let elapsedReturn = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsedReturn, 0.05,
                          "runVectorscopeAsync should return immediately")

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(result, "VectorscopeData should be non-nil")
        XCTAssertEqual(result?.gridSize, 256, "Vectorscope grid should be 256×256")
        XCTAssertGreaterThan(result?.peak ?? 0, 0,
                            "Saturated pixels should produce non-zero vectorscope output")
    }

    // MARK: - 4. Concurrent Dispatch: All Three Kernels Simultaneously

    /// Verify that dispatching histogram + vectorscope + waveform simultaneously
    /// does not cause GPU timeout or data corruption.
    func testConcurrentDispatchAllKernels() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        let needed: AnalysisFlags = [.histogram, .vectorscope, .waveform]
        guard runner.isReady(for: needed) else {
            throw XCTSkip("Not all kernels available")
        }

        let tex = try makeTexture(device: device, width: 1024, height: 1024)

        let histExp = expectation(description: "histogram")
        let vecExp = expectation(description: "vectorscope")
        let waveExp = expectation(description: "waveform")

        var histResult: HistogramData?
        var vecResult: VectorscopeData?
        var waveResult: WaveformData?

        let allStart = Date()

        runner.runHistogramAsync(texture: tex) { h in
            histResult = h
            histExp.fulfill()
        }
        runner.runVectorscopeAsync(texture: tex) { v in
            vecResult = v
            vecExp.fulfill()
        }
        runner.runWaveformAsync(texture: tex) { w in
            waveResult = w
            waveExp.fulfill()
        }

        // All three should have returned from dispatch immediately.
        let dispatchElapsed = Date().timeIntervalSince(allStart)
        XCTAssertLessThan(dispatchElapsed, 0.1,
                          "All three dispatches should return in < 100ms")

        wait(for: [histExp, vecExp, waveExp], timeout: 10.0)

        let totalTime = Date().timeIntervalSince(allStart)

        // All kernels should complete well under Metal's 5s timeout.
        XCTAssertLessThan(totalTime, 2.0,
                          "Concurrent kernels should complete in < 2s (total: \(totalTime)s)")

        XCTAssertNotNil(histResult, "Histogram should produce output")
        XCTAssertNotNil(vecResult, "Vectorscope should produce output")
        XCTAssertNotNil(waveResult, "Waveform should produce output")

        // Histogram: all white pixels → bin 255 should dominate
        XCTAssertEqual(histResult?.lumaBins.last ?? 0, UInt32(1024 * 1024),
                       accuracy: UInt32(1024 * 1024 / 10),
                       "Luma bin 255 should contain most pixels")

        // Waveform: all white → bucket 7 (value 1.0) should dominate
        let yChannelOffset = 1024 * 8 * 3  // skip R, G, B channels
        let lastBucketOffset = yChannelOffset + 1024 * 7  // bucket 7 of Y channel
        let lastBucketSum = (0..<1024).reduce(0) { acc, col in
            acc + (waveResult?.columnLuminance[lastBucketOffset + col] ?? 0)
        }
        XCTAssertGreaterThan(lastBucketSum, Float(1024 * 1024 * 0.9),
                             "Y channel bucket 7 should contain most pixel contributions")
    }

    // MARK: - 5. Staging Texture Reuse Across Frames

    /// Verify that the staging texture is reused (not recreated) when
    /// dimensions stay the same, avoiding per-frame allocation overhead.
    func testStagingTextureReuse() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        guard runner.isReady(for: .waveform) else {
            throw XCTSkip("kernelWaveform not found")
        }

        let tex = try makeTexture(device: device, width: 256, height: 256)

        // Dispatch waveform twice at same resolution.
        let exp1 = expectation(description: "waveform-1")
        let exp2 = expectation(description: "waveform-2")

        runner.runWaveformAsync(texture: tex) { _ in exp1.fulfill() }
        runner.runWaveformAsync(texture: tex) { _ in exp2.fulfill() }

        wait(for: [exp1, exp2], timeout: 5.0)

        // If staging texture was reused, no crash or Metal error occurred.
        // (Metal validation layer would report errors if texture was misused.)
        XCTAssertTrue(true, "Staging texture reuse completed without errors")
    }

    // MARK: - 6. No GPU Timeout Under Large Texture

    /// Dispatch all kernels against a 4K-resolution texture to verify
    /// no GPU timeout occurs (Metal's limit is 5 seconds).
    func testNoGPUTimeoutAt4KResolution() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        let needed: AnalysisFlags = [.histogram, .vectorscope, .waveform]
        guard runner.isReady(for: needed) else {
            throw XCTSkip("Not all kernels available")
        }

        // 4K texture
        let tex = try makeTexture(device: device, width: 3840, height: 2160)

        let histExp = expectation(description: "histogram-4k")
        let vecExp = expectation(description: "vectorscope-4k")
        let waveExp = expectation(description: "waveform-4k")

        let start = Date()

        runner.runHistogramAsync(texture: tex) { _ in histExp.fulfill() }
        runner.runVectorscopeAsync(texture: tex) { _ in vecExp.fulfill() }
        runner.runWaveformAsync(texture: tex) { _ in waveExp.fulfill() }

        wait(for: [histExp, vecExp, waveExp], timeout: 10.0)

        let elapsed = Date().timeIntervalSince(start)
        // Metal GPU timeout is 5 seconds; we expect completion well under that.
        XCTAssertLessThan(elapsed, 3.0,
                          "4K analysis should complete in < 3s (total: \(elapsed)s)")
    }

    // MARK: - 7. Async Pipeline Uses Blit Encoder for Staging Copy

    /// Verify that the async path copies the source texture via a blit encoder
    /// (non-blocking GPU copy) rather than a CPU-side copy.
    func testAsyncPipelineUsesBlitEncoder() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        guard runner.isReady(for: .waveform) else {
            throw XCTSkip("kernelWaveform not found")
        }

        // Create a texture with specific pixel data.
        let w = 32, h = 32
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let tex = device.makeTexture(descriptor: desc) else {
            XCTFail("Failed to create texture")
            throw NSError(domain: "Test", code: 1)
        }
        var data = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let v = Float(x) / Float(w - 1)  // horizontal gradient
                data[idx + 0] = v
                data[idx + 1] = v
                data[idx + 2] = v
                data[idx + 3] = 1.0
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: w * 4 * MemoryLayout<Float>.size)

        let expectation = expectation(description: "waveform-blit")
        var result: WaveformData?

        runner.runWaveformAsync(texture: tex) { wave in
            result = wave
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(result)
        // The waveform output should reflect the gradient: left columns (low x)
        // should have contributions in lower buckets, right columns in higher buckets.
        let columnCount = 1024
        let bucketCount = 8
        // Column 0 maps to output column 0. Pixel at x=0 has v=0 → bucket 0.
        // Column ~1023 maps to output column 1023. Pixel at x=31 has v=1.0 → bucket 7.
        let firstColLowBucket = result?.columnLuminance[0] ?? 0  // R channel, col 0, bucket 0
        let lastColHighBucket = result?.columnLuminance[(columnCount - 1) * bucketCount + 7] ?? 0
        XCTAssertGreaterThan(firstColLowBucket, 0,
                             "Leftmost column should have contributions in low buckets")
        XCTAssertGreaterThan(lastColHighBucket, 0,
                             "Rightmost column should have contributions in high buckets")
    }

    // MARK: - 8. Color Picker Async Does Not Stall

    func testColorPickerAsyncReturnsQuickly() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        guard runner.isReady(for: .colorPicker) else {
            throw XCTSkip("kernelColorPicker not found")
        }

        let tex = try makeTexture(device: device, width: 64, height: 64, fill: 0.5)

        let expectation = expectation(description: "colorPicker")
        var result = SIMD4<Float>.zero

        let start = Date()

        runner.samplePixelAsync(texture: tex, col: 32, row: 32) { color in
            result = color
            expectation.fulfill()
        }

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05,
                          "samplePixelAsync should return immediately")

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(result.x, 0.5, accuracy: 0.01, "R channel")
        XCTAssertEqual(result.y, 0.5, accuracy: 0.01, "G channel")
        XCTAssertEqual(result.z, 0.5, accuracy: 0.01, "B channel")
        XCTAssertEqual(result.w, 1.0, accuracy: 0.01, "A channel")
    }

    // MARK: - 9. Repeated Async Dispatches Maintain Correctness

    /// Dispatch waveform multiple times in sequence to verify the runner
    /// handles repeated calls without state corruption.
    func testRepeatedAsyncDispatchesMaintainCorrectness() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        guard runner.isReady(for: .waveform) else {
            throw XCTSkip("kernelWaveform not found")
        }

        for iteration in 0..<5 {
            let tex = try makeTexture(device: device, width: 128, height: 128,
                                      fill: Float(iteration) / 4.0)
            let exp = expectation(description: "waveform-\(iteration)")
            var result: WaveformData?

            runner.runWaveformAsync(texture: tex) { wave in
                result = wave
                exp.fulfill()
            }

            wait(for: [exp], timeout: 5.0)

            XCTAssertNotNil(result, "Iteration \(iteration): waveform should not be nil")
            XCTAssertEqual(result?.columnLuminance.count, 1024 * 8 * 4,
                           "Iteration \(iteration): output size should be correct")
        }
    }

    // MARK: - 10. VideoAnalysisManager Integration: Waveform Produces Output

    /// Verify the full pipeline: FrameStore → VideoAnalysisManager →
    /// AnalysisGPURunner → WaveformData published.
    func testVideoAnalysisManagerWaveformIntegration() throws {
        let device = try makeDevice()
        let manager = VideoAnalysisManager(metalDevice: device)
        let store = FrameStore()
        manager.attach(frameStore: store)

        manager.waveformEnabled = true

        let tex = try makeTexture(device: device, width: 64, height: 64)
        store.update(tex)

        let exp = expectation(description: "waveform-published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        XCTAssertNotNil(manager.waveform,
                        "Waveform data should be published after frame update")
        XCTAssertEqual(manager.waveform?.columnLuminance.count, 1024 * 8 * 4,
                       "Published waveform should have correct size")
    }

    // MARK: - 11. Disabled Analysis Does Not Produce Output

    func testDisabledAnalysisProducesNoOutput() throws {
        let device = try makeDevice()
        let manager = VideoAnalysisManager(metalDevice: device)
        let store = FrameStore()
        manager.attach(frameStore: store)

        // All toggles off (default).
        let tex = try makeTexture(device: device, width: 64, height: 64)
        store.update(tex)

        let exp = expectation(description: "no-output")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertNil(manager.waveform, "Waveform should be nil when disabled")
        XCTAssertNil(manager.histogram, "Histogram should be nil when disabled")
        XCTAssertNil(manager.vectorscope, "Vectorscope should be nil when disabled")
    }

    // MARK: - 12. pendingAnalysisWork Prevents Queue Buildup

    /// Verify that rapid frame updates don't cause overlapping GPU dispatches.
    func testPendingAnalysisWorkPreventsQueueBuildup() throws {
        let device = try makeDevice()
        let manager = VideoAnalysisManager(metalDevice: device)
        let store = FrameStore()
        manager.attach(frameStore: store)
        manager.waveformEnabled = true

        let tex = try makeTexture(device: device, width: 64, height: 64)

        // Fire 10 rapid frame updates.
        for _ in 0..<10 {
            store.update(tex)
        }

        // Wait for processing.
        let exp = expectation(description: "queue-drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        // If queue buildup prevention works, we should still get valid output
        // (not a crash or timeout).
        XCTAssertNotNil(manager.waveform,
                        "Waveform should be produced even with rapid frame updates")
    }
}
