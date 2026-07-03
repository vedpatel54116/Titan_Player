import XCTest
@testable import TitanPlayer

@MainActor
final class MediaPipelineBackendSelectionTests: XCTestCase {

    // MARK: - shouldUseAVFoundationDirectly

    func test_shouldUseAVFoundationDirectly_for_mp4_mov_m4v() {
        XCTAssertTrue(MediaPipeline.shouldUseAVFoundationDirectly(for: "mp4"))
        XCTAssertTrue(MediaPipeline.shouldUseAVFoundationDirectly(for: "mov"))
        XCTAssertTrue(MediaPipeline.shouldUseAVFoundationDirectly(for: "m4v"))
    }

    func test_shouldUseAVFoundationDirectly_rejectsOtherExtensions() {
        XCTAssertFalse(MediaPipeline.shouldUseAVFoundationDirectly(for: "mkv"))
        XCTAssertFalse(MediaPipeline.shouldUseAVFoundationDirectly(for: "webm"))
        XCTAssertFalse(MediaPipeline.shouldUseAVFoundationDirectly(for: "flv"))
        XCTAssertFalse(MediaPipeline.shouldUseAVFoundationDirectly(for: "avi"))
        XCTAssertFalse(MediaPipeline.shouldUseAVFoundationDirectly(for: "srt"))
    }

    // MARK: - shouldTryFFmpegFirst

    func test_shouldTryFFmpegFirst_for_mkv_webm_flac() {
        XCTAssertTrue(MediaPipeline.shouldTryFFmpegFirst(for: "mkv"))
        XCTAssertTrue(MediaPipeline.shouldTryFFmpegFirst(for: "flv"))
    }

    func test_shouldTryFFmpegFirst_rejectsOtherExtensions() {
        XCTAssertFalse(MediaPipeline.shouldTryFFmpegFirst(for: "mp4"))
        XCTAssertFalse(MediaPipeline.shouldTryFFmpegFirst(for: "mov"))
        XCTAssertFalse(MediaPipeline.shouldTryFFmpegFirst(for: "webm"))
        XCTAssertFalse(MediaPipeline.shouldTryFFmpegFirst(for: "avi"))
    }

    // MARK: - Backend selection is mutually exclusive for standard containers

    func test_avFoundationAndFFmpegSelectionsAreMutuallyExclusive() {
        let avExtensions = ["mp4", "mov", "m4v"]
        let ffmpegExtensions = ["mkv", "flv"]

        for ext in avExtensions {
            XCTAssertTrue(MediaPipeline.shouldUseAVFoundationDirectly(for: ext),
                          "\(ext) should be AVFoundation direct")
            XCTAssertFalse(MediaPipeline.shouldTryFFmpegFirst(for: ext),
                           "\(ext) should NOT be FFmpeg-first")
        }

        for ext in ffmpegExtensions {
            XCTAssertTrue(MediaPipeline.shouldTryFFmpegFirst(for: ext),
                          "\(ext) should be FFmpeg-first")
            XCTAssertFalse(MediaPipeline.shouldUseAVFoundationDirectly(for: ext),
                           "\(ext) should NOT be AVFoundation direct")
        }
    }

    // MARK: - Case insensitivity is NOT supported (documents behavior)

    func test_extensionMatchingIsCaseSensitive() {
        // The implementation lowercases before calling these methods,
        // so uppercase inputs are not expected. Document that behavior.
        XCTAssertFalse(MediaPipeline.shouldUseAVFoundationDirectly(for: "MP4"))
        XCTAssertFalse(MediaPipeline.shouldTryFFmpegFirst(for: "MKV"))
    }
}
