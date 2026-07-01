import Foundation
import Metal
import simd
import Combine
import Dispatch

/// Main facade for the video-analysis toolset. Owns one `AnalysisGPURunner`
/// and one `LFSAudioMeter`, observes `FrameStore` updates, and publishes
/// derived data on the main actor.
@MainActor
final class VideoAnalysisManager: ObservableObject {
    @Published var waveformEnabled: Bool = false
    @Published var vectorscopeEnabled: Bool = false
    @Published var histogramEnabled: Bool = false
    @Published var audioMeteringEnabled: Bool = false

    @Published private(set) var histogram: HistogramData?
    @Published private(set) var waveform: WaveformData?
    @Published private(set) var vectorscope: VectorscopeData?
    @Published private(set) var colorPicker: ColorSample?

    let runner: AnalysisGPURunner
    let audioMeter: LFSAudioMeter

    private weak var frameStore: FrameStore?
    private var frameIDSink: AnyCancellable?
    private let gpuQueue = DispatchQueue(label: "com.titanplayer.analysis.gpu",
                                         qos: .userInitiated)
    private var lastDispatchAt: Date = .distantPast

    /// Tracks in-flight async analysis calls to avoid overlapping dispatches.
    private var pendingAnalysisWork: Int = 0

    /// Source-pixel dimensions of the latest frame (nil before any frame arrives).
    var latestTextureSize: CGSize? {
        guard let t = frameStore?.latestTexture else { return nil }
        return CGSize(width: t.width, height: t.height)
    }

    init(metalDevice: MTLDevice) {
        self.runner = AnalysisGPURunner(device: metalDevice)
        self.audioMeter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
    }

    func attach(frameStore: FrameStore) {
        self.frameStore = frameStore
        frameIDSink = frameStore.frameIDPublisher
            .receive(on: gpuQueue)
            .sink { [weak self] _ in
                self?.handleFrameTick()
            }
    }

    private func handleFrameTick() {
        let now = Date()
        if now.timeIntervalSince(lastDispatchAt) < (1.0 / 30.0) { return }
        lastDispatchAt = now

        // Skip if analysis is already in-flight (prevents queue buildup).
        guard pendingAnalysisWork == 0 else { return }

        var needed: AnalysisFlags = []
        if histogramEnabled   { needed.insert(.histogram) }
        if vectorscopeEnabled { needed.insert(.vectorscope) }
        if waveformEnabled    { needed.insert(.waveform) }
        guard !needed.isEmpty else { return }
        guard let tex = frameStore?.latestTexture else { return }
        guard runner.isReady(for: needed) else { return }

        pendingAnalysisWork += 1

        // Use async GPU dispatch – each call enqueues work on the analysis
        // command queue and returns immediately, keeping the render pipeline
        // unblocked at 60 fps.
        if needed.contains(.histogram) {
            runner.runHistogramAsync(texture: tex) { [weak self] hOut in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let h = hOut { self.histogram = h }
                }
            }
        }
        if needed.contains(.vectorscope) {
            runner.runVectorscopeAsync(texture: tex) { [weak self] vOut in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let v = vOut { self.vectorscope = v }
                }
            }
        }
        if needed.contains(.waveform) {
            runner.runWaveformAsync(texture: tex) { [weak self] wOut in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let w = wOut { self.waveform = w }
                    self.pendingAnalysisWork -= 1
                }
            }
        } else {
            // No waveform – decrement count so we don't stall forever.
            pendingAnalysisWork -= 1
        }
    }

    /// Sample a single pixel from the latest frame and wrap the result in a
    /// `ColorSample`. Returns `nil` if no texture is currently available.
    func sampleColor(at col: Int, row: Int) async -> ColorSample? {
        guard let tex = frameStore?.latestTexture else { return nil }
        let v = await withCheckedContinuation { (cont: CheckedContinuation<SIMD4<Float>, Never>) in
            runner.samplePixelAsync(texture: tex, col: col, row: row) { result in
                cont.resume(returning: result)
            }
        }
        let sample = ColorSample(r: v.x, g: v.y, b: v.z, a: v.w)
        self.colorPicker = sample
        return sample
    }
}
