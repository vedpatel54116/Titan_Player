# Mac Compatibility Matrix

This document enumerates the Mac models that TitanPlayer explicitly supports,
and the hardware decoder / HDR capabilities each one is expected to provide.
The runtime expectations are encoded in
`TitanPlayer/TitanPlayer/Core/Hardware/MacModelIdentifier.swift` and
`DecoderCapabilities.swift`, and exercised in
`TitanPlayer/Tests/Hardware/`.

The matrix is anchored on macOS 14+ (the project's deployment target). Newer
SoCs inherit the previous tier's capabilities plus any new ones shown below;
older SoCs are downgraded.

## Matrix

| Model | sysctl | HWH264 | HWHEVC | ProRes | ProResRAW | AV1 | HDR10 | HLG | DolbyVision P5 | DolbyVision P8 |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| MBP Intel 2018 (baseline) | MacBookPro15,x | YES | – | – | – | – | – | – | – | – |
| Intel unknown | `intel.unknown` | YES | – | – | – | – | – | – | – | – |
| Mac mini M1 | Macmini9,1 | YES | YES | YES | – | – | YES | YES | – | – |
| iMac M1 | iMac21,1 | YES | YES | YES | – | – | YES | YES | – | – |
| MacBookPro M1 Pro | MacBookPro17,1 | YES | YES | YES | – | – | YES | YES | – | – |
| MacBookPro M1 Max | MacBookPro18,1 | YES | YES | YES | – | – | YES | YES | – | – |
| Mac Studio M1 Ultra | Mac13,2 | YES | YES | YES | – | – | YES | YES | – | – |
| Mac mini M2 | Macmini14,2 | YES | YES | YES | YES | – | YES | YES | – | – |
| MacBookPro M2 Pro | MacBookPro19,1 | YES | YES | YES | YES | – | YES | YES | – | – |
| MacBookPro M2 Max | MacBookPro19,2 | YES | YES | YES | YES | – | YES | YES | – | – |
| Mac Pro M2 Ultra | Mac14,13 | YES | YES | YES | YES | – | YES | YES | – | – |
| MacBookPro M3 Pro | MacBookPro21,1 | YES | YES | YES | YES | YES | YES | YES | YES | – |
| MacBookPro M4 Pro | MacBookPro16,3 | YES | YES | YES | YES | YES | YES | YES | YES | YES |
| Mac mini M4 | Macmini16,1 | YES | YES | YES | YES | YES | YES | YES | YES | YES |

"Tier" grouping used by `HardwareCodecProfile.detect()`:

| Tier | Models |
|---|---|
| Intel baseline | MBP 2018, generic intel |
| Apple M1 tier | M1, M1 Pro, M1 Max, M1 Ultra, iMac M1 |
| Apple M2 tier | M2, M2 Pro, M2 Max, M2 Ultra, M2 Ultra Studio |
| Apple M3 tier | M3 Pro |
| Apple M4 tier | M4 Pro, Mac mini M4 |

## In-CI coverage

GitHub Actions macOS runners ship Apple Silicon (M1-class at the time of
writing). The unit-test target therefore reliably exercises:

- `HardwareCodecProfile.detect()` returning the Apple M1 tier
- `MacModelIdentifier.detect()` returning the host's `sysctl hw.model`
- Test injection of every other tier to assert per-tier capability differences

Real-hardware validation across the full matrix is recorded manually in
`docs/M_COMPAT_VALIDATION_LOG.md` (soak runs, regression reruns).

## Smoke test entry point

Run, from the repo root:

```bash
make compat-smoke
```

…which invokes `swift test --filter Hardware` and reports per-tier pass/fail.
