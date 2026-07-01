#!/usr/bin/env bash
# scripts/dist-prep-check.sh
# Runs every textual lint that the App Store prep artifacts require.
# Works in a CommandLineTools-only environment (no Xcode required).

set -euo pipefail

info() { printf "  ok %s\n" "$*"; }
fail() { printf "  FAIL %s\n" "$*" >&2; exit 1; }

echo "== plist / entitlements lint =="
for f in \
  TitanPlayer/TitanPlayer/Info.plist \
  TitanPlayer/TitanPlayer/TitanPlayer.entitlements \
  TitanPlayer/TitanPlayer/TitanPlayer.Direct.entitlements; do
  [[ -f "$f" ]] || fail "missing $f"
  xmllint --noout "$f" || fail "xmllint failed for $f"
  plutil -lint "$f" >/dev/null || fail "plutil -lint failed for $f"
  info "$f"
done

echo "== project.yml lint =="
ruby -ryaml -e 'YAML.load_file("TitanPlayer/project.yml")' >/dev/null \
  || fail "project.yml Ruby/YAML load failed"
info "TitanPlayer/project.yml"

# Sanity: both entitlements must be referenced from project.yml.
echo "== project.yml references both entitlements =="
ruby -ryaml -e '
  s = YAML.load_file("TitanPlayer/project.yml").to_s
  abort("AppStore entitlements path missing from project.yml") unless s.include?("TitanPlayer.entitlements")
  abort("Direct entitlements path missing from project.yml")   unless s.include?("TitanPlayer.Direct.entitlements")
  puts "  ok both entitlements referenced"
'

echo "== asset catalog JSON =="
ruby -rjson -e '
  files = %w[
    TitanPlayer/TitanPlayer/Resources/Assets.xcassets/Contents.json
    TitanPlayer/TitanPlayer/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
  ]
  files.each do |f|
    JSON.parse(File.read(f))
    puts "  ok #{f}"
  end
'

echo "== AppIcon.appiconset completeness =="
ruby -rjson -e '
  j = JSON.parse(File.read("TitanPlayer/TitanPlayer/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"))
  base = "TitanPlayer/TitanPlayer/Resources/Assets.xcassets/AppIcon.appiconset"
  missing = j["images"].map { |i| i["filename"] }.reject { |f| File.exist?("#{base}/#{f}") }
  abort("AppIcon slot files missing: #{missing.inspect}") unless missing.empty?
  puts "  ok #{j["images"].length} image slots, all files present"
'

echo "== LICENSE + PRIVACY.md presence =="
[[ -s LICENSE ]]    || fail "LICENSE missing or empty"
grep -q "MIT License" LICENSE || fail "LICENSE not MIT"
info "LICENSE (MIT)"
[[ -s PRIVACY.md ]] || fail "PRIVACY.md missing or empty"
info "PRIVACY.md"

echo "== fastlane metadata Apple character limits =="
ruby -e '
  files = {
    "name.txt"          => 30,
    "subtitle.txt"      => 30,
    "description.txt"   => 4000,
    "keywords.txt"      => 100,
    "release_notes.txt" => 4000,
    "privacy_url.txt"   => 255,
    "support_url.txt"   => 255,
    "marketing_url.txt" => 255,
    "copyright.txt"     => 200
  }
  any = false
  files.each do |name, lim|
    path = "fastlane/metadata/en-US/#{name}"
    abort("missing #{path}") unless File.exist?(path)
    len = File.read(path).strip.length
    abort("  FAIL #{name}: #{len} chars > #{lim}") if len > lim
    puts "  ok #{name}: #{len}/#{lim}"
  end
'

echo "== fastlane Ruby lint =="
ruby -c fastlane/Appfile >/dev/null  || fail "fastlane/Appfile syntax error"
info "fastlane/Appfile"
ruby -c fastlane/Fastfile >/dev/null || fail "fastlane/Fastfile syntax error"
info "fastlane/Fastfile"

echo "== xcodegen regeneration (smoke) =="
if command -v xcodegen >/dev/null 2>&1; then
  ( cd TitanPlayer && xcodegen generate --spec project.yml --project .. ) >/dev/null 2>&1 \
    || fail "xcodegen generate failed"
  if [[ -f TitanPlayer.xcodeproj/project.pbxproj ]]; then
    info "TitanPlayer.xcodeproj/project.pbxproj regenerated ($(wc -l < TitanPlayer.xcodeproj/project.pbxproj) lines)"
  else
    fail "xcodegen succeeded but pbxproj is missing"
  fi
else
  info "skipped (xcodegen not installed)"
fi

echo "== SwiftPM still builds =="
( cd TitanPlayer && swift build 2>&1 | tail -5 ) || fail "swift build failed"
info "swift build"

echo
echo "ALL CHECKS PASSED"
