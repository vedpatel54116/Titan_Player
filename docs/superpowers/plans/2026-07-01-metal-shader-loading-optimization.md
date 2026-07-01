# Metal Shader Loading Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pre-compile Metal shaders into a `default.metallib` at build time and load it at runtime, eliminating error-prone runtime concatenation and reducing startup latency.

**Architecture:** Xcode Run Script build phase compiles `.metal` → `.air` → `default.metallib`. `MetalShaders.loadLibrary()` tries the pre-compiled metallib first, then falls back to an improved runtime concatenation for SwiftPM CLI builds. A validation script catches shader errors at build time.

**Tech Stack:** Metal CLI (`xcrun metal`, `xcrun metallib`), Swift, MTLDevice API, Xcode project configuration

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Scripts/validate-shaders.sh` | Create | Build-time shader validation script |
| `TitanPlayer/TitanPlayer/Core/Renderers/MetalShaders.swift` | Modify | Add metallib loading, improve fallback |
| `TitanPlayer.xcodeproj/project.pbxproj` | Modify | Add Metal compilation build phase |

---

### Task 1: Create Shader Validation Script

**Files:**
- Create: `Scripts/validate-shaders.sh`

- [ ] **Step 1: Create the Scripts directory**

```bash
mkdir -p Scripts
```

- [ ] **Step 2: Write the validation script**

```bash
#!/bin/bash
# Scripts/validate-shaders.sh
# Validates Metal shader files compile without errors.
# Run: bash Scripts/validate-shaders.sh
# Returns non-zero exit code on any shader compilation failure.

set -euo pipefail

SHADER_DIR="${1:-TitanPlayer/Resources/Shaders}"
METAL_BIN="${METAL_BIN:-$(xcrun --sdk macosx --find metal)}"
FAILED=0

echo "Validating Metal shaders in ${SHADER_DIR}..."
echo "Using Metal compiler: ${METAL_BIN}"

for shader in "${SHADER_DIR}"/*.metal; do
    [ -f "$shader" ] || continue
    name=$(basename "$shader")
    echo -n "  ${name}... "
    if "$METAL_BIN" -c "$shader" -o /dev/null 2>&1; then
        echo "OK"
    else
        echo "FAILED"
        "$METAL_BIN" -c "$shader" -o /dev/null
        FAILED=1
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo "Shader validation FAILED"
    exit 1
fi

echo "All shaders validated successfully"
```

- [ ] **Step 3: Make the script executable**

```bash
chmod +x Scripts/validate-shaders.sh
```

- [ ] **Step 4: Run the validation script to verify it works**

```bash
bash Scripts/validate-shaders.sh
```

Expected: All 4 shaders print "OK" and the script exits 0.

- [ ] **Step 5: Commit**

```bash
git add Scripts/validate-shaders.sh
git commit -m "feat: add Metal shader validation script"
```

---

### Task 2: Add Pre-compiled Metallib Loading to MetalShaders.swift

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalShaders.swift`

- [ ] **Step 1: Add metallib search locations to `locateShaderFile` and a new `locateMetallib` method**

Replace the entire `MetalShaders.swift` with:

```swift
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
```

- [ ] **Step 2: Verify the file compiles**

```bash
cd TitanPlayer && swift build 2>&1 | tail -5
```

Expected: Build succeeds with no errors related to MetalShaders.swift.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalShaders.swift
git commit -m "feat: add pre-compiled metallib loading and auto forward declarations"
```

---

### Task 3: Add Xcode Build Phase for Metal Compilation

**Files:**
- Modify: `TitanPlayer.xcodeproj/project.pbxproj`

This task adds a Run Script build phase that compiles `.metal` → `.air` → `default.metallib` and copies it into the bundle resources.

- [ ] **Step 1: Add PBXShellScriptBuildPhase section entry**

Open `TitanPlayer.xcodeproj/project.pbxproj`. Find the line:

```
/* Begin PBXShellScriptBuildPhase section */
```

Add the following block immediately after that line (before the existing `FAB7914D28523A347A1397BA` entry):

```
		A1B2C3D4E5F6000112345601 /* Compile Metal Shaders */ = {
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
				"$(SRCROOT)/TitanPlayer/Resources/Shaders/Common.metal",
				"$(SRCROOT)/TitanPlayer/Resources/Shaders/Video.metal",
				"$(SRCROOT)/TitanPlayer/Resources/Shaders/HDR.metal",
				"$(SRCROOT)/TitanPlayer/Resources/Shaders/Analysis.metal",
			);
			name = "Compile Metal Shaders";
			outputFileListPaths = (
			);
			outputPaths = (
				"$(BUILT_PRODUCTS_DIR)/$(RESOURCE_FOLDER_PATH)/default.metallib",
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "set -euo pipefail\n\nSHADER_DIR=\"${SRCROOT}/TitanPlayer/Resources/Shaders\"\nMETAL_BIN=\"${SDKROOT}/usr/bin/metal\"\nOUT_DIR=\"${BUILT_PRODUCTS_DIR}/${RESOURCE_FOLDER_PATH}\"\n\nmkdir -p \"${OUT_DIR}\"\n\n# Compile each .metal to .air\nfor shader in \"${SHADER_DIR}\"/*.metal; do\n    [ -f \"$shader\" ] || continue\n    name=$(basename \"$shader\" .metal)\n    echo \"Compiling ${name}.metal...\"\n    \"$METAL_BIN\" -c \"$shader\" -o \"${OUT_DIR}/${name}.air\"\ndone\n\n# Link all .air into default.metallib\nMETALLIB_INPUTS=\"\"\nfor air in \"${OUT_DIR}\"/*.air; do\n    [ -f \"$air\" ] || continue\n    METALLIB_INPUTS=\"${METALLIB_INPUTS} ${air}\ndone\n\nif [ -z \"${METALLIB_INPUTS}\" ]; then\n    echo \"error: No .air files found, cannot create default.metallib\"\n    exit 1\nfi\n\necho \"Linking default.metallib...\"\nxcrun metallib ${METALLIB_INPUTS} -o \"${OUT_DIR}/default.metallib\"\necho \"Created ${OUT_DIR}/default.metallib\"\n\n# Clean up .air files\nrm -f \"${OUT_DIR}\"/*.air\n";
		};
```

- [ ] **Step 2: Add the build phase reference to the target's build phases array**

Find the target's `buildPhases` array (look for the one containing `FAB7914D28523A347A1397BA /* Run Script */`). Add the new reference before the existing Run Script entry:

```
				A1B2C3D4E5F6000112345601 /* Compile Metal Shaders */,
				FAB7914D28523A347A1397BA /* Run Script */,
```

The exact location is in the `PBXNativeTarget` section. Search for:

```
buildPhases = (
```

under the TitanPlayer target, and insert the new line before the existing `FAB7914D28523A347A1397BA` entry.

- [ ] **Step 3: Verify the project file is valid**

```bash
cd TitanPlayer && swift build 2>&1 | tail -5
```

Expected: Build succeeds. The Xcode project file parses correctly.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer.xcodeproj/project.pbxproj
git commit -m "feat: add Metal shader compilation build phase to Xcode project"
```

---

### Task 4: End-to-End Verification

**Files:** None (verification only)

- [ ] **Step 1: Run shader validation script**

```bash
bash Scripts/validate-shaders.sh
```

Expected: All 4 shaders compile successfully.

- [ ] **Step 2: Build the project**

```bash
cd TitanPlayer && swift build 2>&1 | tail -10
```

Expected: Build succeeds with no errors.

- [ ] **Step 3: Check for duplicate symbol warnings**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "duplicate" || echo "No duplicate warnings"
```

Expected: "No duplicate warnings"

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "fix: shader loading optimization final adjustments"
```
