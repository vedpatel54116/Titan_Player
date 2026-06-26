import SwiftUI
import MetalKit

struct MetalMtkView: NSViewRepresentable {
    let renderer: FrameRendering

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        if let metalRenderer = renderer as? MetalRenderer {
            metalRenderer.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // v1: no-op. Future: re-attach if renderer identity changes.
    }
}
