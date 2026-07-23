import XCTest
@testable import TitanPlayer

@MainActor
final class MockTelemetry: TelemetryProviding {
    var isOptedIn: Bool = true
    var needsConsentPrompt: Bool = false
    private(set) var recorded: [TelemetryEvent] = []

    func initialize() {}
    func record(_ event: TelemetryEvent) { recorded.append(event) }
    func setConsent(_ granted: Bool) {}
}

final class MediaErrorTests: XCTestCase {

    // MARK: Classification

    func testURLErrorTimedOutMapsToTimedOut() {
        let error = MediaError(URLError(.timedOut), source: .hls)
        XCTAssertEqual(error.kind, .timedOut)
        XCTAssertEqual(error.telemetryErrorCode, "timed_out")
    }

    func testURLErrorNotConnectedMapsToNetworkUnavailable() {
        let error = MediaError(URLError(.notConnectedToInternet), source: .dash)
        XCTAssertEqual(error.kind, .networkUnavailable)
    }

    func testCancellationErrorMapsToCancelled() {
        let error = MediaError(CancellationError(), source: .local)
        XCTAssertEqual(error.kind, .cancelled)
        XCTAssertEqual(error.telemetryErrorCode, "cancelled")
    }

    func testPOSIXTimeoutMapsToTimedOut() {
        let nsError = NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
        let error = MediaError(nsError, source: .local)
        XCTAssertEqual(error.kind, .timedOut)
    }

    func testAVErrorNoSourceTrackMapsToNoPlayableTracks() {
        let avError = AVError.noSourceTrack as NSError
        let error = MediaError(avError, source: .local)
        XCTAssertEqual(error.kind, .noPlayableTracks)
    }

    func testUnknownErrorDefaultsToUnknown() {
        struct WeirdError: Error {}
        let error = MediaError(WeirdError(), source: .local)
        XCTAssertEqual(error.kind, .unknown)
    }

    // MARK: Legacy compatibility

    func testLegacyCodeMessageRoundTrip() {
        let error = MediaError(code: .fileNotFound, message: "Missing file")
        XCTAssertEqual(error.code, .fileNotFound)
        XCTAssertEqual(error.message, "Missing file")
        XCTAssertEqual(error.errorDescription, "Missing file")
        XCTAssertEqual(error.kind, .invalidURL)
    }

    func testComputedErrorCodeBridgesKind() {
        XCTAssertEqual(MediaError(.invalidURL, source: .local).code, .fileNotFound)
        XCTAssertEqual(MediaError(.decodingFailed, source: .local).code, .decodingFailed)
        XCTAssertEqual(MediaError(.networkUnavailable, source: .local).code, .networkError)
        XCTAssertEqual(MediaError(.thermalPressure, source: .local).code, .systemPressure)
        XCTAssertEqual(MediaError(.memoryPressure, source: .local).code, .systemPressure)
        XCTAssertEqual(MediaError(.cancelled, source: .local).code, .systemPressure)
        XCTAssertEqual(MediaError(.timedOut, source: .local).code, .systemPressure)
    }

    // MARK: Codable

    func testCodableRoundTripPreservesSourceViaRawValue() throws {
        let original = MediaError(.rendererFailure, source: .hls,
                                  underlyingDomain: "MTLCommandBufferErrorDomain",
                                  underlyingCode: 4,
                                  underlyingMessage: "device lost",
                                  codec: "hevc",
                                  resolution: "3840x2160",
                                  message: "Renderer failed")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaError.self, from: data)
        XCTAssertEqual(decoded.kind, .rendererFailure)
        XCTAssertEqual(decoded.source, .hls)
        XCTAssertEqual(decoded.codec, "hevc")
        XCTAssertEqual(decoded.resolution, "3840x2160")
        XCTAssertEqual(decoded.underlyingDomain, "MTLCommandBufferErrorDomain")
    }

    func testCodableRecoversLocalWhenSourceUnknown() throws {
        let json = #"{"kind":"unknown","source":"martian","message":"boom","timestamp":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MediaError.self, from: json)
        XCTAssertEqual(decoded.source, .local)
        XCTAssertEqual(decoded.kind, .unknown)
    }

    // MARK: System-pressure factories

    func testThermalPressureFactory() {
        let error = MediaError.thermalPressure()
        XCTAssertEqual(error.kind, .thermalPressure)
        XCTAssertEqual(error.telemetryErrorCode, "thermal_pressure")
    }

    func testMemoryPressureFactoryWithBytes() {
        let error = MediaError.memoryPressure(availableBytes: 512 * 1024 * 1024)
        XCTAssertEqual(error.kind, .memoryPressure)
        XCTAssertEqual(error.telemetryErrorCode, "memory_pressure")
        XCTAssertNotNil(error.underlyingMessage)
    }

    // MARK: Telemetry hook (protocol only, never Sentry)

    @MainActor
    func testRecordUsingTelemetryRoutesToPlaybackFailed() {
        let error = MediaError(.timedOut, source: .local, codec: "av1", resolution: "1920x1080")
        let mock = MockTelemetry()
        error.record(using: mock)

        XCTAssertEqual(mock.recorded.count, 1)
        guard case .playbackFailed(let codec, let resolution, let errorCode, let source) = mock.recorded[0] else {
            return XCTFail("Expected playbackFailed event")
        }
        XCTAssertEqual(codec, "av1")
        XCTAssertEqual(resolution, "1920x1080")
        XCTAssertEqual(errorCode, "timed_out")
        XCTAssertEqual(source, .local)
    }
}
