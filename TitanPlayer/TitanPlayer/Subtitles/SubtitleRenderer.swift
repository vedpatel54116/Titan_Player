import Foundation
import Metal

/// Result of rendering subtitle events at a given time.
/// Automatically frees the pixel buffer when deallocated.
final class SubtitleBitmap {
    let pixels: UnsafeMutableRawBufferPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: MTLPixelFormat  // Always .bgra8Unorm

    init(pixels: UnsafeMutableRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, pixelFormat: MTLPixelFormat) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
    }

    deinit {
        pixels.deallocate()
    }
}

/// Abstracts subtitle rendering backends (libass, SwiftUI fallback, etc.).
protocol SubtitleRenderer {
    /// Parse subtitle data from raw bytes.
    func load(data: Data, encoding: String.Encoding) throws

    /// Render active subtitle events at the given time to a bitmap.
    /// Returns nil if no events are active at this time.
    func renderImage(forTime time: Double, size: CGSize) -> SubtitleBitmap?

    /// Override default style (font, size, colors) for the loaded track.
    func setStyleSheet(_ style: SubtitleStyle)

    /// Free all loaded data and reset state.
    func flush()
}
