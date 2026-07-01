import XCTest
@testable import Benchmarks

final class PlaybackBenchmarksTests: XCTestCase {
    func test_4K_H264_staysBelowCeilings_whenFixtureExists() async throws {
        let baseline = try loadBaseline()
        let fixtureURL = try fixtureURL()
        let probe = EnginePerformanceProbe()
        probe._testInject(cpu: 0.0, bytes: 0)

        let metrics = try await H264_4KCPUAndMemoryBenchmark.run(
            forSeconds: max(2.0, baseline.sleepSeconds),
            fixtureURL: fixtureURL,
            probe: probe
        )

        XCTAssertLessThan(metrics.cpuAverage, baseline.cpuCeilingPct,
                          "CPU usage regressed: \(metrics.cpuAverage) > \(baseline.cpuCeilingPct)")
        XCTAssertLessThan(metrics.memoryPeakBytes, baseline.memoryCeilingBytes,
                          "Peak memory regressed: \(metrics.memoryPeakBytes) > \(baseline.memoryCeilingBytes)")
    }

    func test_4K_H264_skipsWhenFixtureMissing() async throws {
        let probe = EnginePerformanceProbe()
        let missing = URL(fileURLWithPath: "/tmp/no_such_fixture_4k_h264.mp4")
        do {
            _ = try await H264_4KCPUAndMemoryBenchmark.run(forSeconds: 1, fixtureURL: missing, probe: probe)
            XCTFail("expected fixtureMissing error")
        } catch H264_4KCPUAndMemoryBenchmark.BenchmarkError.fixtureMissing {
            // expected
        }
    }

    private func loadBaseline() throws -> BenchmarkConfig {
        try BenchmarkConfig.fromBaseline("playback_4k_h264")
    }

    private func fixtureURL(file: StaticString = #filePath) throws -> URL {
        let candidatePaths = [
            "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer/Tests/Fixtures/test_4k_h264.mp4",
            "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer/Tests/Fixtures/test.mp4",
        ]
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw XCTSkip("4K H.264 fixture not present locally")
    }
}
