//
//  MetalMtkView.swift
//  TitanPlayer
//
//  SwiftUI wrapper for MTKView with frame pacing support.
//

import SwiftUI
import MetalKit

/// SwiftUI wrapper around MTKView for Metal rendering.
struct MirrorMTKView: NSViewRepresentable {
    let frameStore: FrameStore
    var preferredFPS: Int = 60

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.preferredFramesPerSecond = preferredFPS
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        // Don't clear automatically — the renderer manages clears
        mtkView.autoResizeDrawable = true
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Update FPS if content frame rate changes
        if nsView.preferredFramesPerSecond != preferredFPS {
            nsView.preferredFramesPerSecond = preferredFPS
        }
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: ()) {
        nsView.delegate = nil
        nsView.device = nil
    }
}
