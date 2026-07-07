import XCTest
@testable import TitanPlayer

@MainActor
final class MediaPipelineBackendRoutingTests: XCTestCase {

    func testBackendDirectForStandardContainers() {
        for ext in ["mp4", "mov", "m4v"] {
            XCTAssertEqual(
                MediaPipeline.backend(for: ext),
                .avFoundationDirect,
                "Expected .avFoundationDirect for \(ext)"
            )
        }
    }

    func testBackendFFmpegPreferredForContainersNeedingDemuxing() {
        for ext in ["flv", "mkv", "webm", "ts", "ogv", "wmv", "avi", "3gp", "rm"] {
            XCTAssertEqual(
                MediaPipeline.backend(for: ext),
                .ffmpegPreferred,
                "Expected .ffmpegPreferred for \(ext)"
            )
        }
    }

    func testBackendFallbackForUnrecognizedExtensions() {
        for ext in ["xyz", "abc", "dat", "bin"] {
            XCTAssertEqual(
                MediaPipeline.backend(for: ext),
                .avFoundationFallback,
                "Expected .avFoundationFallback for \(ext)"
            )
        }
    }
}
