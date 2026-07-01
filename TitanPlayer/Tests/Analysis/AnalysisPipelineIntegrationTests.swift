import XCTest
import Metal
@testable import TitanPlayer

@MainActor
final class AnalysisPipelineIntegrationTests: XCTestCase {
    func testSessionOwnsAnalysisAndAttachesFrameStore() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let session = PlaybackSession(videoRenderer: MockFrameRenderer(),
                                      audioRenderer: MockAudioRenderer())
        XCTAssertNotNil(session.analysis)
        XCTAssertNotNil(session.frameStore)
        // The analysis manager should not be collecting when nothing is enabled.
        XCTAssertFalse(session.analysis.histogramEnabled)
        XCTAssertFalse(session.analysis.waveformEnabled)
        XCTAssertFalse(session.analysis.vectorscopeEnabled)
        XCTAssertFalse(session.analysis.audioMeteringEnabled)
    }
}
