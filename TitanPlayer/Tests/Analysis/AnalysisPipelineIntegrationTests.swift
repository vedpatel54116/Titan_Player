import XCTest
import Metal
@testable import TitanPlayer

@MainActor
final class AnalysisPipelineIntegrationTests: XCTestCase {
    func testSessionOwnsAnalysisAndAttachesFrameStore() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let session = PlaybackSession(videoRenderer: MockFrameRenderer())
        XCTAssertNotNil(session.analysis)
        XCTAssertNotNil(session.frameStore)
        // The analysis manager should not be collecting when nothing is enabled.
        XCTAssertFalse(session.analysis?.histogramEnabled ?? true)
        XCTAssertFalse(session.analysis?.waveformEnabled ?? true)
        XCTAssertFalse(session.analysis?.vectorscopeEnabled ?? true)
        XCTAssertFalse(session.analysis?.audioMeteringEnabled ?? true)
    }
}
