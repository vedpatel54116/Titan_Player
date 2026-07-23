import XCTest
import os
@testable import TitanPlayer

@available(macOS 14, iOS 17, tvOS 17, *)
final class TelemetryAggregatorTests: XCTestCase {

    /// A capturing sink that records every batch forwarded by the aggregator.
    private final class CapturingSink {
        let lock = OSAllocatedUnfairLock<[TelemetryEvent]>(initialState: [])
        var events: [TelemetryEvent] { lock.withLock { $0 } }
        var flushCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        var onFlush: @Sendable ([TelemetryEvent]) async -> Void {
            { [weak self] batch in
                self?.lock.withLock { $0.append(contentsOf: batch) }
                self?.flushCount.withLock { $0 += 1 }
            }
        }
    }

    private var aggregator: TelemetryAggregator!
    private var sink: CapturingSink!

    override func setUp() {
        super.setUp()
        sink = CapturingSink()
        let config = TelemetryAggregator.Configuration(
            maxBatchSize: 1,
            flushInterval: .seconds(1),
            flushTimeout: .seconds(2),
            consent: { true },
            onFlush: sink.onFlush
        )
        aggregator = TelemetryAggregator(configuration: config)
    }

    override func tearDown() {
        aggregator?.stop()
        aggregator = nil
        sink = nil
        super.tearDown()
    }

    /// Aggregating a thrown error must be mapped to the centralized ``MediaError``
    /// and forwarded as a sanitized `playbackFailed` event.
    func testAggregateErrorMapsToMediaError() async throws {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: nil)
        aggregator.aggregate(error: error, source: .local, codec: "hevc", resolution: "3840x2160")

        try await Task.sleep(nanoseconds: 200_000_000)
        let captured = sink.events
        XCTAssertEqual(captured.count, 1)
        guard case .playbackFailed(let codec, let resolution, let errorCode, let source) = captured[0] else {
            return XCTFail("Expected playbackFailed event")
        }
        XCTAssertEqual(errorCode, "asset_load_failed")
        XCTAssertEqual(codec, "hevc")
        XCTAssertEqual(resolution, "3840x2160")
        XCTAssertEqual(source, .local)
    }

    /// Free-form strings must be redacted before they are buffered.
    func testSanitizationStripsPII() {
        XCTAssertEqual(aggregator.sanitize("/Users/ved/video.mov"), "[redacted-path]")
        XCTAssertEqual(aggregator.sanitize("https://secret.example.com/stream"), "[redacted-url]")
        XCTAssertEqual(aggregator.sanitize("192.168.0.42"), "[redacted-ip]")
        XCTAssertEqual(aggregator.sanitize("user@titan.example"), "[redacted-email]")
        XCTAssertEqual(aggregator.sanitize("hevc"), "hevc")
    }

    /// Events must not be buffered once consent is withdrawn.
    func testConsentGateDropsEvents() async throws {
        let config = TelemetryAggregator.Configuration(
            maxBatchSize: 1,
            consent: { false },
            onFlush: sink.onFlush
        )
        let gated = TelemetryAggregator(configuration: config)
        gated.aggregate(.hdrModeUsed(mode: .hdr10, duration: 10))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(sink.events.isEmpty)
        gated.stop()
    }

    /// Thermal and memory pressure must be surfaced as ``MediaError`` events.
    func testSystemPressureMapsToMediaError() async throws {
        aggregator.startMonitoringSystemPressure()
        // Simulate the pressure handlers directly for a deterministic test.
        let thermal = TitanPlayer.MediaError.thermalPressure()
        let memory = TitanPlayer.MediaError.memoryPressure()
        aggregator.aggregate(error: thermal, source: .local)
        aggregator.aggregate(error: memory, source: .hls)

        try await Task.sleep(nanoseconds: 200_000_000)
        let errorCodes = sink.events.compactMap { event -> String? in
            guard case .playbackFailed(_, _, let code, _) = event else { return nil }
            return code
        }
        XCTAssertTrue(errorCodes.contains("thermal_pressure"))
        XCTAssertTrue(errorCodes.contains("memory_pressure"))
    }

    /// `stop()` must flush any remaining buffered events.
    func testStopFlushesRemaining() async throws {
        let config = TelemetryAggregator.Configuration(
            maxBatchSize: 100,
            flushInterval: .seconds(1_000),
            consent: { true },
            onFlush: sink.onFlush
        )
        let batched = TelemetryAggregator(configuration: config)
        batched.aggregate(.audioFormatUsed(format: .atmos, sampleRate: 48000, bitDepth: 24))
        // Give the eager path (maxBatchSize not reached) a moment, then stop.
        batched.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sink.events.count, 1)
    }
}
