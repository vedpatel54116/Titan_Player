import Foundation
import CLibAss
import Metal

/// Renders ASS/SSA subtitles using libass.
/// Returns nil from init() if libass is not available (graceful fallback).
class LibAssRenderer: SubtitleRenderer {
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ASS_Track>?
    private var ownedBuffer: UnsafeMutablePointer<UInt8>?
    private var ownedBufferSize: Int = 0

    init?() {
        guard let lib = ass_library_init() else { return nil }
        self.library = lib

        guard let rend = ass_renderer_init(lib) else {
            ass_library_done(lib)
            self.library = nil
            return nil
        }
        self.renderer = rend

        configureFonts()
    }

    deinit {
        flush()
        if let renderer = renderer { ass_renderer_done(renderer) }
        if let library = library { ass_library_done(library) }
    }

    // MARK: - SubtitleRenderer

    func load(data: Data, encoding: String.Encoding) throws {
        flush()

        let count = data.count
        let buf = malloc(count)!
        data.copyBytes(to: buf.assumingMemoryBound(to: UInt8.self), count: count)
        ownedBuffer = buf.assumingMemoryBound(to: UInt8.self)
        ownedBufferSize = count

        track = ass_read_memory(
            library,
            UnsafeMutableRawPointer(buf).assumingMemoryBound(to: CChar.self),
            count,
            nil
        )
    }

    func renderImage(forTime time: Double, size: CGSize) -> SubtitleBitmap? {
        guard let track = track, let renderer = renderer else { return nil }

        let width = Int32(size.width)
        let height = Int32(size.height)
        ass_set_frame_size(renderer, width, height)

        var eventCount: Int32 = 0
        guard let image = ass_render_frame(renderer, track, Int64(time * 1000), &eventCount) else {
            return nil
        }
        guard eventCount > 0 else { return nil }

        return compositeImages(image, width: Int(width), height: Int(height))
    }

    func setStyleSheet(_ style: SubtitleStyle) {
        guard let library = library else { return }
        let fontNameEntry = "FontName=\(style.fontName)"
        let fontSizeEntry = "Fontsize=\(Int(style.fontSize))"

        var entries: [UnsafeMutablePointer<CChar>?] = [
            fontNameEntry.withCString { strdup($0) },
            fontSizeEntry.withCString { strdup($0) },
            nil
        ]

        entries.withUnsafeMutableBufferPointer { ptr in
            ass_set_style_overrides(library, ptr.baseAddress)
        }

        for entry in entries where entry != nil {
            free(entry)
        }
    }

    func flush() {
        if let track = track { ass_free_track(track) }
        track = nil
        if let buf = ownedBuffer { free(buf) }
        ownedBuffer = nil
        ownedBufferSize = 0
    }

    // MARK: - Private

    private func configureFonts() {
        guard let renderer = renderer else { return }
        let fontDirs = [
            NSHomeDirectory() + "/Library/Fonts",
            "/Library/Fonts",
            "/System/Library/Fonts"
        ]
        for dir in fontDirs {
            dir.withCString { cStr in
                ass_set_fonts_dir(renderer, cStr)
            }
        }
    }

    private func compositeImages(_ first: UnsafeMutablePointer<ASS_Image>,
                                  width: Int,
                                  height: Int) -> SubtitleBitmap? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        guard let buffer = malloc(totalBytes) else { return nil }
        memset(buffer, 0, totalBytes)

        var current: UnsafeMutablePointer<ASS_Image>? = first
        while let img = current {
            let imgW = Int(img.pointee.w)
            let imgH = Int(img.pointee.h)
            let stride = Int(img.pointee.stride)
            let dstX = Int(img.pointee.dst_x)
            let dstY = Int(img.pointee.dst_y)

            guard imgW > 0, imgH > 0,
                  dstX >= 0, dstY >= 0,
                  dstX + imgW <= width, dstY + imgH <= height else {
                current = img.pointee.next
                continue
            }

            let dst = buffer.assumingMemoryBound(to: UInt8.self)
            let bitmap = img.pointee.bitmap!

            for y in 0..<imgH {
                let srcRow = bitmap.advanced(by: y * stride)
                let dstOffset = (dstY + y) * bytesPerRow + dstX * bytesPerPixel

                for x in 0..<imgW {
                    let srcAlpha = srcRow.advanced(by: x).pointee
                    let off = dstOffset + x * bytesPerPixel

                    dst[off + 0] = 255  // B
                    dst[off + 1] = 255  // G
                    dst[off + 2] = 255  // R
                    dst[off + 3] = srcAlpha  // A
                }
            }

            current = img.pointee.next
        }

        let bufferPtr = UnsafeMutableRawBufferPointer(start: buffer, count: totalBytes)
        return SubtitleBitmap(
            pixels: bufferPtr,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra8Unorm
        )
    }
}
