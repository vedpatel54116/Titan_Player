import Foundation
import Libavutil
import CoreVideo

/// Sendable wrapper around an `AVFrame` pointer. Owns the underlying frame
/// and frees it on deinit, preventing accidental double-free across threads.
// SAFETY: This box owns a single AVFrame pointer and frees it in deinit.
// The pointer is not shared — it is transferred across isolation boundaries
// as an owning reference. No concurrent mutation occurs after init.
final class FFmpegFrameBox: @unchecked Sendable {
    let ptr: UnsafeMutablePointer<AVFrame>

    init(_ ptr: UnsafeMutablePointer<AVFrame>) {
        self.ptr = ptr
    }

    deinit {
        av_frame_unref(ptr)
        var p: UnsafeMutablePointer<AVFrame>? = ptr
        av_frame_free(&p)
    }
}
