# Metal Shader Loading Optimization

## Problem

`MetalShaders.loadLibrary()` falls back to runtime MSL compilation by concatenating `.metal` files and stripping headers. This is:
- **Error-prone**: Manual header stripping, hardcoded forward declarations
- **Slow**: Runtime compilation adds startup latency
- **Fragile**: No compile-time validation of shader correctness

## Solution

Three-part optimization:

### 1. Xcode Build Phase — Pre-compile Shaders

Add a Run Script build phase that compiles `.metal` → `default.metallib` at build time:

```sh
# Compile each .metal to .air
for shader in TitanPlayer/Resources/Shaders/*.metal; do
    xcrun metal -c "$shader" -o "${shader%.metal}.air"
done

# Link all .air into default.metallib
xcrun metallib TitanPlayer/Resources/Shaders/*.air \
    -o "$BUILT_PRODUCTS_DIR/$RESOURCE_FOLDER/default.metallib"
```

- **Input paths**: `TitanPlayer/Resources/Shaders/*.metal`
- **Output path**: `$BUILT_PRODUCTS_DIR/$RESOURCE_FOLDER/default.metallib`
- **SDK**: Uses `$SDKROOT/usr/bin/metal` for correct SDK version
- **Failure mode**: Build fails if any shader has compilation errors

### 2. MetalShaders.swift — New Loading Order

Updated `loadLibrary()` tries paths in order:

1. `device.makeDefaultLibrary()` — unchanged (Xcode-linked metallib)
2. **NEW**: `Bundle.module.url(forResource: "default", withExtension: "metallib")` → `device.makeLibrary(filepath:)` — loads pre-compiled metallib from bundle
3. Runtime concatenation fallback — improved (for SwiftPM CLI builds)

Key changes:
- `locateShaderFile()` refactored to also search for `.metallib` files
- New `loadPrecompiledMetallib(device:)` method for path #2

### 3. Improved Runtime Fallback

For SwiftPM CLI builds where no metallib exists:

- **`#include` resolution**: Parse `#include` directives and inline referenced file content
- **Duplicate symbol detection**: Track declared symbols, warn on duplicates
- **Auto forward declarations**: Parse combined source, generate forward declarations for functions called before definition (replaces hardcoded `hdrForwardDecls`)
- **Syntax validation**: Check matching braces and no unterminated strings before calling `makeLibrary(source:)`

### 4. Compile-time Validation Script

New `Scripts/validate-shaders.sh`:
- Runs `xcrun metal -c` on each `.metal` file
- Reports errors with file names and line numbers
- Returns non-zero on failure
- Usable manually or in CI

## Files to Modify

| File | Change |
|------|--------|
| `TitanPlayer.xcodeproj/project.pbxproj` | Add Run Script build phase for Metal compilation |
| `TitanPlayer/TitanPlayer/Core/Renderers/MetalShaders.swift` | Add metallib loading path, improve fallback |
| `Scripts/validate-shaders.sh` | New file — shader validation script |

## Acceptance Criteria

- Shaders load successfully on first launch without runtime compilation errors
- No duplicate symbol warnings in console
- Faster startup time due to pre-compiled metallib
- Build fails if shaders have compilation errors (catches issues early)
- Runtime fallback still works for SwiftPM CLI builds
