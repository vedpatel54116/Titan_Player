import XCTest
import AVFAudio
@testable import TitanPlayer

final class AudioDiagnosticsTests: XCTestCase {
    func testAudioDiagnosticsInitialization() {
        let diagnostics = AudioDiagnostics()

        XCTAssertNotNil(diagnostics)
        XCTAssertEqual(diagnostics.logLevel, .info)
    }

    func testAudioDiagnosticsLogging() {
        let diagnostics = AudioDiagnostics()
        diagnostics.logLevel = .debug

        diagnostics.log("Test message", level: .debug)
    }
}
