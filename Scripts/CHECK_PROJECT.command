#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== Hand AR Browser V25 project check =="
for f in "HandARBrowser.xcodeproj/project.pbxproj" "HandARBrowser/AppDelegate.swift" "HandARBrowser/MainViewController.swift" "HandARBrowser/Info.plist" "HandARBrowser/WebInput.js"; do
  [[ -f "$f" ]] && echo "[OK] $f" || { echo "[FAIL] missing $f"; exit 1; }
done

grep -Fq "final class EyeDisplayView" HandARBrowser/MainViewController.swift
grep -Fq "private let eyeLeft = EyeDisplayView()" HandARBrowser/MainViewController.swift
grep -Fq "private let eyeRight = EyeDisplayView()" HandARBrowser/MainViewController.swift
grep -Fq "AnchorEntity(anchor: anchor)" HandARBrowser/MainViewController.swift
grep -Fq "didUpdate anchors: [ARAnchor]" HandARBrowser/MainViewController.swift
grep -Fq "input.updateBoth(" HandARBrowser/MainViewController.swift
! grep -Fq "EyeContainer" HandARBrowser/MainViewController.swift
! grep -Fq "EyeBridgeView" HandARBrowser/MainViewController.swift
! grep -Fq "LensMaskView" HandARBrowser/MainViewController.swift
! grep -Fq "fillEllipse" HandARBrowser/MainViewController.swift
! grep -Fq "panel.position =" HandARBrowser/MainViewController.swift
! grep -Fq "panel.layer.position =" HandARBrowser/MainViewController.swift
! grep -Fq "normalized(SIMD3<Float>" HandARBrowser/MainViewController.swift

if command -v swiftc >/dev/null 2>&1; then
  swiftc -parse HandARBrowser/MainViewController.swift
  echo "[OK] Swift parser"
else
  echo "[WARN] swiftc is not available. Open this project on macOS with Xcode."
fi

if command -v xcodebuild >/dev/null 2>&1; then
  echo "[OK] xcodebuild: $(xcodebuild -version | head -1)"
else
  echo "[WARN] xcodebuild is not available."
fi

echo "PASS"
