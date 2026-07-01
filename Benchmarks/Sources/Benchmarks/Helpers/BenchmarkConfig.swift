import Foundation

/// Per-metric baseline ceiling loaded from a JSON resource bundled with
/// `Benchmarks`. Mirrors `coverage.threshold.json` in spirit:
/// thresholds are data, not code.
struct BenchmarkConfig: Decodable {
    let cpuCeilingPct: Double
    let memoryCeilingBytes: Int64
    let iterations: Int

    enum LoadError: Error, CustomStringConvertible {
        case missingResource(String)
        case malformed(String)
        var description: String {
            switch self {
            case .missingResource(let s): return "benchmark baseline not found: \(s)"
            case .malformed(let s): return "benchmark baseline malformed: \(s)"
            }
        }
    }

    /// Load `<baselinesDir>/<name>.json`, where `name` may or may not
    /// include the `.json` suffix.
    static func fromBaseline(
        _ name: String,
        resourceDir: String = "Baselines",
        bundle: Bundle = .module
    ) throws -> BenchmarkConfig {
        let stem = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
        guard let url = bundle.url(forResource: stem, withExtension: "json", subdirectory: resourceDir) else {
            throw LoadError.missingResource("\(resourceDir)/\(stem).json")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(BenchmarkConfig.self, from: data)
        } catch {
            throw LoadError.malformed("\(error)")
        }
    }
}
