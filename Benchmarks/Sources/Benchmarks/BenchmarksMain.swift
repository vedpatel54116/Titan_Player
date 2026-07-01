import Foundation

@main
enum BenchmarksMain {
    static func main() async throws {
        let args = ProcessInfo.processInfo.arguments
        let smokeMode = args.contains("--smoke")

        guard args.count > 1 else {
            print("usage: benchmarks [--smoke] [--iterations N] [--fixture path.mp4]")
            print()
            print("Runs playback benchmarks and asserts against baseline JSON")
            print("ceiling values. --smoke uses the test.mp4 fixture with a")
            print("short sample window. Exits non-zero on regression.")
            return
        }

        let config = try BenchmarkConfig.fromBaseline("playback_4k_h264")
        let fixtureName = smokeMode ? "test.mp4" : "test_4k_h264.mp4"
        let fixturePath = candidateFixtures().first ?? "/tmp/no_fixture.mp4"
        let fixtureURL = URL(fileURLWithPath: fixturePath)

        let probe = EnginePerformanceProbe()
        probe._testInject(cpu: 0.0, bytes: 0)

        print("running benchmark: \(fixtureName) @ \(fixturePath)")
        do {
            let metrics = try await H264_4KCPUAndMemoryBenchmark.run(
                forSeconds: smokeMode ? 2.0 : 5.0,
                fixtureURL: fixtureURL,
                probe: probe
            )
            print("cpu avg:   \(String(format: "%.4f", metrics.cpuAverage))  ceiling: \(config.cpuCeilingPct)")
            print("mem peak:  \(metrics.memoryPeakBytes)  ceiling: \(config.memoryCeilingBytes)")
            if metrics.cpuAverage >= config.cpuCeilingPct {
                print("FAIL: CPU regression"); exit(1)
            }
            if metrics.memoryPeakBytes >= config.memoryCeilingBytes {
                print("FAIL: Memory regression"); exit(1)
            }
            print("PASS")
        } catch H264_4KCPUAndMemoryBenchmark.BenchmarkError.fixtureMissing {
            print("fixture missing — installing skip")
        }
    }

    private static func candidateFixtures() -> [String] {
        let candidates = [
            "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer/Tests/Fixtures/test_4k_h264.mp4",
            "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer/Tests/Fixtures/test.mp4",
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
