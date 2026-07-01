#!/usr/bin/env python3
"""
coverage-gate.py

Reads `coverage.threshold.json` (next to repo root) and `swift test
--enable-code-coverage` profile data; exits non-zero if the threshold isn't
met.

Usage:
  python3 scripts/coverage-gate.py [profdata]

Exit codes:
  0 - threshold met
  1 - threshold not met
  2 - profile / binary not available (typically env-limited: needs Xcode, not
      CommandLineTools)
"""
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPM = ROOT / "TitanPlayer"
THRESHOLD_PATH = ROOT / "coverage.threshold.json"
PROFDATA = SPM / ".build/debug/codecov/default.profdata"
BINARY = SPM / ".build/debug/TitanPlayerPackageTests.xctest"
THRESHOLD = json.loads(THRESHOLD_PATH.read_text())


def find_summary_pct(text: str) -> float:
    """Locate llvm-cov 'TOTAL' line percentage in text export."""
    m = re.search(r"(?m)^[\s]*TOTAL[\s:]+.*?(\d+\.\d+)\s*%", text)
    if m:
        return float(m.group(1))
    # Fallback: any 'XX.YY%' near 'TOTAL' word
    for line in text.splitlines():
        if "TOTAL" in line:
            match = re.search(r"(\d+\.\d+)\s*%", line)
            if match:
                return float(match.group(1))
    return 0.0


def main() -> int:
    if not THRESHOLD_PATH.exists():
        print(f"missing {THRESHOLD_PATH}", file=sys.stderr)
        return 1
    threshold_pct = float(THRESHOLD.get("total_pct", 90.0))
    if not PROFDATA.exists() or not BINARY.exists():
        print(
            "coverage profile or test bundle not present "
            f"(env likely lacks Xcode). skipping gate. look in {PROFDATA}",
            file=sys.stderr,
        )
        return 2
    out = subprocess.check_output(
        [
            "xcrun",
            "llvm-cov",
            "export",
            str(BINARY),
            "-instr-profile",
            str(PROFDATA),
            "-format=text",
        ],
        text=True,
    )
    total_pct = find_summary_pct(out)
    print(f"coverage total: {total_pct:.2f}%  threshold: {threshold_pct:.2f}%")
    if total_pct >= threshold_pct:
        return 0
    print(
        f"FAIL: {total_pct:.2f}% < {threshold_pct:.2f}%",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
