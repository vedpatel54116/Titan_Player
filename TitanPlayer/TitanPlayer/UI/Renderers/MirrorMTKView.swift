import SwiftUI
import MetalKit

struct MirrorMTKView: NSViewRepresentable {
    let frameStore: FrameStore

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let delegate = MirrorViewDelegate(frameStore: frameStore)
        view.delegate = delegate
        context.coordinator.delegate = delegate
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var delegate: MirrorViewDelegate?
    }
}

final class MirrorViewDelegate: NSObject, MTKViewDelegate {
    private weak var frameStore: FrameStore?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var lastSeenFrameID: UInt64 = 0

    init(frameStore: FrameStore) {
        self.frameStore = frameStore
        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let store = frameStore,
              let sourceTexture = store.latestTexture else {
            return
        }

        guard store.frameID != lastSeenFrameID else { return }
        lastSeenFrameID = store.frameID

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0, sourceLevel: 0,
            to: drawable.texture,
            destinationSlice: 0, destinationLevel: 0,
            sliceCount: 1, levelCount: 1
        )
        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
