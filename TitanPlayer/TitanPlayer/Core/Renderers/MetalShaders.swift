import Foundation
import Metal

/// Loads Metal shader libraries, preferring pre-compiled `.metallib` bundles
/// and falling back to runtime MSL compilation from bundled `.metal` sources.
enum MetalShaders {
    static let sourceFileNames = ["Common", "Video", "HDR", "Analysis"]
    static let resourceBundleName = "TitanPlayer_TitanPlayer.bundle"

    /// Returns a Metal library for the device. Tries in order:
    /// 1. Embedded default.metallib (linked by Xcode)
    /// 2. Pre-compiled default.metallib in bundle resources
    /// 3. Runtime compilation from bundled .metal sources (SwiftPM fallback)
    static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        if let lib = device.makeDefaultLibrary() {
            return lib
        }
        if let lib = loadPrecompiledMetallib(device: device) {
            return lib
        }
        guard let source = loadCombinedSource() else { return nil }
        return try? device.makeLibrary(source: source, options: nil)
    }

    // MARK: - Pre-compiled metallib loading

    private static func loadPrecompiledMetallib(device: MTLDevice) -> MTLLibrary? {
        guard let url = locateMetallib(named: "default") else { return nil }
        return try? device.makeLibrary(filepath: url.path)
    }

    private static func locateMetallib(named name: String) -> URL? {
        let file = "\(name).metallib"
        var candidates: [URL] = []
        if let m = Bundle.module.url(forResource: name, withExtension: "metallib") {
            candidates.append(m)
        }
        for b in bundleNameURLs() {
            candidates.append(b.appendingPathComponent(file))
            candidates.append(b.appendingPathComponent("Contents/Resources").appendingPathComponent(file))
            candidates.append(b.appendingPathComponent("Resources").appendingPathComponent(file))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    // MARK: - Runtime source compilation (SwiftPM fallback)

    private static func loadCombinedSource() -> String? {
        var found = false
        let preamble = "#include <metal_stdlib>\nusing namespace metal;\n"
        var body = ""
        for name in sourceFileNames {
            guard let url = locateShaderFile(named: name),
                  let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = stripRedundantHeaders(raw)
            body += "\n// ----- \(name).metal -----\n" + stripped + "\n"
            found = true
        }
        guard found else { return nil }
        let combined = preamble + body
        let withForwardDecls = generateForwardDeclarations(combined)
        return withForwardDecls
    }

    /// Parses the combined Metal source and generates forward declarations
    /// for functions that are called before they are defined.
    private static func generateForwardDeclarations(_ source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        var definedSymbols: Set<String> = []
        var forwardDecls: [String] = []
        let keywordPattern = #"^(?:static\s+inline\s+|inline\s+)?(?:float[234]|int[234]|uint[234]|half[234]|bool|void|float|int|uint|half|bool)\s+(\w+)\s*\("#

        for line in lines {
            if let range = line.range(of: keywordPattern, options: .regularExpression) {
                let match = String(line[range])
                if let nameRange = match.range(of: #"\b(\w+)\s*\("#, options: .regularExpression) {
                    let nameMatch = String(match[nameRange])
                    let name = nameMatch.replacingOccurrences(of: "(", with: "").trimmingCharacters(in: .whitespaces)
                    definedSymbols.insert(name)
                }
            }
        }

        var calledBeforeDefined: Set<String> = []
        var seenDefinitions: Set<String> = []
        let callPattern = #"(\w+)\s*\("#

        for line in lines {
            if let range = line.range(of: keywordPattern, options: .regularExpression) {
                let match = String(line[range])
                if let nameRange = match.range(of: #"\b(\w+)\s*\("#, options: .regularExpression) {
                    let nameMatch = String(match[nameRange])
                    let name = nameMatch.replacingOccurrences(of: "(", with: "").trimmingCharacters(in: .whitespaces)
                    seenDefinitions.insert(name)
                }
                continue
            }

            if let regex = try? NSRegularExpression(pattern: callPattern) {
                let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
                let matches = regex.matches(in: line, range: nsRange)
                for m in matches {
                    if let r = Range(m.range(at: 1), in: line) {
                        let callee = String(line[r])
                        if definedSymbols.contains(callee) && !seenDefinitions.contains(callee) {
                            calledBeforeDefined.insert(callee)
                        }
                    }
                }
            }
        }

        if calledBeforeDefined.isEmpty { return source }

        for name in calledBeforeDefined.sorted() {
            forwardDecls.append("static inline float \(name)(/* see definition below */);")
        }

        let declBlock = "\n// ----- Auto-generated forward declarations -----\n" +
            forwardDecls.joined(separator: "\n") + "\n"

        if let insertPoint = source.range(of: "// ----- HDR forward decls -----\n") {
            return source.replacingCharacters(in: insertPoint.lowerBound..<insertPoint.lowerBound, with: declBlock)
        }
        if let insertPoint = source.range(of: "// ----- HDR.metal -----") {
            return source.replacingCharacters(in: insertPoint.lowerBound..<insertPoint.lowerBound, with: declBlock)
        }
        return declBlock + source
    }

    /// Strips `#include <metal_stdlib>` and `using namespace metal;` from
    /// individual files since we emit them once in the preamble.
    private static func stripRedundantHeaders(_ source: String) -> String {
        var s = source
        let patterns = [
            "#include <metal_stdlib>\nusing namespace metal;",
            "#include <metal_stdlib>",
            "using namespace metal;"
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func locateShaderFile(named name: String) -> URL? {
        let file = "\(name).metal"
        var candidates: [URL] = []
        if let m = Bundle.module.url(forResource: name, withExtension: "metal") {
            candidates.append(m)
        }
        for b in bundleNameURLs() {
            candidates.append(b.appendingPathComponent(file))
            candidates.append(b.appendingPathComponent("Contents/Resources").appendingPathComponent(file))
            candidates.append(b.appendingPathComponent("Resources").appendingPathComponent(file))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func bundleNameURLs() -> [URL] {
        let main = Bundle.main.bundleURL
        return [
            main.appendingPathComponent(resourceBundleName),
            main.appendingPathComponent("Contents/Resources").appendingPathComponent(resourceBundleName),
        ]
    }
}
