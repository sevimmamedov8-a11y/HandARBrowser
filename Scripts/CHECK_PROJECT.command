#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== Hand AR Browser project check =="
for f in "HandARBrowser.xcodeproj/project.pbxproj" "HandARBrowser/AppDelegate.swift" "HandARBrowser/MainViewController.swift" "HandARBrowser/Info.plist" "HandARBrowser/WebInput.js"; do
  [[ -f "$f" ]] && echo "[OK] $f" || { echo "[FAIL] missing $f"; exit 1; }
done
if command -v xcodebuild >/dev/null 2>&1; then
  echo "[OK] xcodebuild: $(xcodebuild -version | head -1)"
else
  echo "[WARN] xcodebuild is not available. Open this project on macOS with Xcode."
fi
echo "PASS"
