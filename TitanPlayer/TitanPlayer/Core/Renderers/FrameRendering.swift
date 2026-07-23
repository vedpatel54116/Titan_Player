//
//  FrameRendering.swift
//  TitanPlayer
//
//  Protocol for video frame renderers.
//

import MetalKit
import CoreVideo

/// A renderer that can display decoded video frames.
protocol FrameRendering: AnyObject {
    /// Attach the renderer to an MTKView.
    func attach(to view: MTKView)

    /// Detach the renderer from its view.
    func detach()

    /// Render a decoded video frame.
    func render(_ frame: VideoFrame) async throws

    /// Flush all queued/pending frames (called on seek).
    func flushFrames()

    /// Number of frames waiting to be rendered.
    var pendingFrameCount: Int { get }

    /// Whether the renderer is in fallback mode.
    var fallbackActive: Bool { get set }
}

/// No-op renderer used when Metal is unavailable.
final class NoOpFrameRenderer: FrameRendering {
    var fallbackActive = false
    var pendingFrameCount: Int { 0 }

    func attach(to view: MTKView) {}
    func detach() {}
    func render(_ frame: VideoFrame) async throws {}
    func flushFrames() {}
}
