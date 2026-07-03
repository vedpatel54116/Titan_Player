.PHONY: help test coverage benchmarks ui-tests compat-smoke clean dist-prep-check dist-prep-build

# Default target prints help.
help:
	@echo "TitanPlayer testing strategy targets:"
	@echo "  make test          - swift test (unit, integration, perf filtered)"
	@echo "  make coverage      - swift test --enable-code-coverage + threshold gate"
	@echo "  make benchmarks    - swift run --package-path Benchmarks Benchmarks"
	@echo "  make ui-tests      - xcodebuild test against the parallel .xcodeproj"
	@echo "  make compat-smoke  - swift test --filter Hardware"
	@echo ""
	@echo "Distribution preparation targets (Phase 7 / Prompt 13):"
	@echo "  make dist-prep-check - lint plists, entitlements, fastlane metadata, xcodegen, swift build"
	@echo "  make dist-prep-build - print user-side build & notarization commands (Xcode required)"

# Path constants — the SwiftPM Package.swift lives at TitanPlayer/.
SPM_DIR := TitanPlayer
BENCH_DIR := Benchmarks
PROJECT := TitanPlayer.xcodeproj

test:
	cd $(SPM_DIR) && swift test --parallel

coverage: coverage.threshold.json scripts/coverage-gate.py
	cd $(SPM_DIR) && swift test --enable-code-coverage --parallel
	python3 scripts/coverage-gate.py

benchmarks:
	swift run --package-path $(BENCH_DIR) Benchmarks

ui-tests:
	xcodebuild -project $(PROJECT) -scheme TitanPlayerUITests test

compat-smoke:
	cd $(SPM_DIR) && swift test --filter Hardware --parallel

# Metal shader pre-compilation — eliminates first-launch runtime MSL compilation stutter.
# Run once (or whenever .metal files change) before building:
#   make precompile-shaders
SHADERS_DIR := TitanPlayer/TitanPlayer/Resources/Shaders
SHADERS_OUTPUT_DIR := TitanPlayer/TitanPlayer/Resources
METAL_FILES := $(wildcard $(SHADERS_DIR)/*.metal)
AIR_FILES := $(patsubst $(SHADERS_DIR)/%.metal, $(SHADERS_DIR)/%.air, $(METAL_FILES))

$(SHADERS_DIR)/%.air: $(SHADERS_DIR)/%.metal
	xcrun -sdk macosx metal -c $< -o $@

precompile-shaders: $(AIR_FILES)
	xcrun -sdk macosx metallib $(SHADERS_DIR)/*.air -o $(SHADERS_OUTPUT_DIR)/default.metallib
	rm -f $(SHADERS_DIR)/*.air
	@echo "Pre-compiled default.metallib written to $(SHADERS_OUTPUT_DIR)"

clean:
	cd $(SPM_DIR) && swift package clean
	rm -rf $(SPM_DIR)/.build
	rm -f $(SHADERS_DIR)/*.air

# Run every textual lint for App Store prep artifacts.
# Works on CommandLineTools-only machines; no Xcode required.
dist-prep-check:
	bash scripts/dist-prep-check.sh

# Full user-side build & notarization (requires Xcode + Apple Developer account).
# Documented here; executed manually by the developer.
dist-prep-build:
	@echo "App Store build:"
	@echo "  brew install xcodegen"
	@echo "  cd TitanPlayer && xcodegen generate --spec project.yml --project .."
	@echo "  open TitanPlayer.xcodeproj"
	@echo
	@echo "Mac App Store:"
	@echo "  cd fastlane && fastlane metadata_only"
	@echo "  cd fastlane && fastlane mas"
	@echo
	@echo "Developer ID (notarized):"
	@echo "  cd fastlane && fastlane direct"
