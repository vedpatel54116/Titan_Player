import Metal

@MainActor
final class PlaybackTelemetryCoordinator {
    let performance: PerformanceOptimizer
    let analysis: VideoAnalysisManager?

    init(
        metalRenderer: MetalRenderer?,
        engine: PlaybackEngine,
        streaming: StreamingManager,
        frameStore: FrameStore
    ) {
        let perf = PerformanceOptimizer.makeDefault()
        var analysisManager: VideoAnalysisManager?

        if let metal = metalRenderer {
            perf.registerAdapter(RenderAdapter(target: metal))
            if let device = MTLCreateSystemDefaultDevice() {
                let mgr = VideoAnalysisManager(metalDevice: device)
                mgr.attach(frameStore: frameStore)
                analysisManager = mgr
            }
        }
        perf.registerAdapter(DecoderAdapter(target: engine.adaptiveDecoderManager))
        perf.registerAdapter(StreamingAdapter(target: streaming))

        self.performance = perf
        self.analysis = analysisManager
    }

    func startMonitor() {
        Task.detached(priority: .background) { [performance] in
            performance.startPerformanceMonitor()
        }
    }
}
