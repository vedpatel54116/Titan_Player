# Icon Placeholder

The icons in `../Assets.xcassets/AppIcon.appiconset/` were procedurally-generated
by `../../../scripts/render-placeholder-icon.swift`. They are a clean baseline
that renders correctly in every required App Store size and is suitable for
local development.

**This is a placeholder; you must replace these PNGs with a real, branded
master 1024×1024 PNG before submitting to the Mac App Store.**

To regenerate or update, edit `render-placeholder-icon.swift` and rerun:

```bash
swift scripts/render-placeholder-icon.swift \
  TitanPlayer/TitanPlayer/Resources/Assets.xcassets/AppIcon.appiconset \
  16 32 64 128 256 512 1024
```

The intended workflow after brand sign-off:

1. Drop a 1024×1024 master PNG at `master.png` (replace the procedurally-rendered one).
2. Use `iconutil --convert icns` to compile it into a `.icns` if a non-App-Store build is needed.
3. Re-run the script with proper sizes from Apple's "App Icon - macOS" spec.
