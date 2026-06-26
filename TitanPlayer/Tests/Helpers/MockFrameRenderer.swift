import AppKit
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class MockFrameRenderer: FrameRendering {
    private(set) var renderedFrames: [VideoFrame] = []
    private(set) var hdrMetadatas: [HDRMetadata] = []
    private(set) var screensSnapshot: [NSScreen] = []
    private(set) var dynamicResetCount = 0
    var renderError: Error?

    func render(_ frame: VideoFrame) async throws {
        if let err = renderError { throw err }
        renderedFrames.append(frame)
    }

    func handleHDR(_ metadata: HDRMetadata) {
        hdrMetadatas.append(metadata)
    }

    func updateDisplayCapabilities(for screen: NSScreen) {
        screensSnapshot.append(screen)
    }

    func resetDynamicHDRParams() {
        dynamicResetCount += 1
    }
}
