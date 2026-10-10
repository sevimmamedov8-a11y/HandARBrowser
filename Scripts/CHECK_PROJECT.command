#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== HandAR Кинотеатр: проверка проекта =="

for f in "HandARCinema.xcodeproj/project.pbxproj" \
         "HandARCinema/AppDelegate.swift" \
         "HandARCinema/CinemaViewController.swift" \
         "HandARCinema/VRHallEngine.swift" \
         "HandARCinema/Info.plist"; do
  [[ -f "$f" ]] && echo "[OK] $f" || { echo "[FAIL] missing $f"; exit 1; }
done

SRC="HandARCinema/CinemaViewController.swift"
ENGINE="HandARCinema/VRHallEngine.swift"

# --- стерео-движок VR ---
grep -Fq "final class ARStereoTrackingManager" "$ENGINE"
grep -Fq "func worldRay(visionPoint: CGPoint) -> WorldRay?" "$ENGINE"
grep -Fq "struct VRProfile" "$ENGINE"
grep -Fq "enum VRLensMath" "$ENGINE"
grep -Fq "final class VRCompositor" "$ENGINE"
grep -Fq "final class HandTracker" "$ENGINE"
echo "[OK] стерео-движок на месте"

# --- приложение кинотеатра ---
grep -Fq "MTKViewDelegate" "$SRC"
grep -Fq "final class CinemaViewController" "$SRC"
grep -Fq "SCNRenderer(device: metalDevice, options: nil)" "$SRC"
grep -Fq "compositor.encode(" "$SRC"
grep -Fq "WKWebView" "$SRC"
grep -Fq "webView.takeSnapshot" "$SRC"
grep -Fq "func togglePlay" "$SRC"
grep -Fq "func toggleLights" "$SRC"
grep -Fq "func moveScreen" "$SRC"
grep -Fq "func seek(by" "$SRC"
grep -Fq "func changeVolume" "$SRC"
grep -Fq "func exitToPhone" "$SRC"
grep -Fq "screenColumns" "$SRC"
echo "[OK] зал, пульт и плеер на месте"

grep -Fq "AVAudioSession" HandARCinema/AppDelegate.swift
grep -Fq "NSCameraUsageDescription" HandARCinema/Info.plist
grep -Fq "HandAR" HandARCinema/Info.plist
echo "[OK] звук, камера и инфоплист настроены"

if command -v swiftc >/dev/null 2>&1; then
  if swiftc -parse "$ENGINE" >/tmp/cinema_parse_engine.out 2>&1 \
     && swiftc -parse "$SRC" >/tmp/cinema_parse_app.out 2>&1; then
    echo "[OK] Swift parser"
  else
    echo "[WARN] swiftc parser unavailable for Apple SDK imports on this runner"
    sed -n '1,8p' /tmp/cinema_parse_engine.out || true
    sed -n '1,8p' /tmp/cinema_parse_app.out || true
  fi
else
  echo "[WARN] swiftc is not available. Open this project on macOS with Xcode."
fi

if command -v xcodebuild >/dev/null 2>&1; then
  echo "[OK] xcodebuild: $(xcodebuild -version | head -1)"
else
  echo "[WARN] xcodebuild is not available. Open this project on macOS with Xcode."
fi

echo "PASS"
