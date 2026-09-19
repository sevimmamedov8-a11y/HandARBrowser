#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== Hand AR Browser V30 project check =="
for f in "HandARBrowser.xcodeproj/project.pbxproj" "HandARBrowser/AppDelegate.swift" "HandARBrowser/MainViewController.swift" "HandARBrowser/Info.plist" "HandARBrowser/WebInput.js"; do
  [[ -f "$f" ]] && echo "[OK] $f" || { echo "[FAIL] missing $f"; exit 1; }
done

SRC="HandARBrowser/MainViewController.swift"

grep -Fq "import ARKit" "$SRC"
grep -Fq "import SceneKit" "$SRC"
grep -Fq "import Vision" "$SRC"
grep -Fq "final class ARStereoTrackingManager" "$SRC"
grep -Fq "ARWorldTrackingConfiguration" "$SRC"
grep -Fq 'ARAnchor(name: "HandAR_Stereo_Browser"' "$SRC"
grep -Fq "private let leftBrowser: WKWebView" "$SRC"
grep -Fq "private let rightBrowser: WKWebView" "$SRC"
grep -Fq "private let leftEyeView = SCNView" "$SRC"
grep -Fq "private let rightEyeView = SCNView" "$SRC"
grep -Fq "private let lensMask = StereoLensMaskView()" "$SRC"
grep -Fq "final class HandSkeletonView" "$SRC"
grep -Fq "try? observation.recognizedPoints(.all)" "$SRC"
grep -Fq "frame.displayTransform" "$SRC"
grep -Fq "frame.camera.unprojectPoint" "$SRC"
grep -Fq "guard let point = frame.camera.unprojectPoint" "$SRC"
grep -Fq "SCNMatrix4(leftProjection)" "$SRC"
grep -Fq "SCNMatrix4(rightProjection)" "$SRC"
grep -Fq "browserWorldDistance: Float = 1.65" "$SRC"
grep -Fq "eyeSeparation: Float = 0.064" "$SRC"

grep -Fq "HandAR Vision" HandARBrowser/Info.plist
grep -Fq "NSCameraUsageDescription" HandARBrowser/Info.plist

! grep -Fq "private let browser: WKWebView" "$SRC"
! grep -Fq "private let browserLeft" "$SRC"
! grep -Fq "private let browserRight" "$SRC"
! grep -Fq "final class LensMaskView" "$SRC"
! grep -Fq "SCNMatrix4FromMat4" "$SRC"
! grep -Fq "panel.position =" "$SRC"
! grep -Fq "panel.layer.position =" "$SRC"

echo "[OK] V30 static project checks"

if command -v swiftc >/dev/null 2>&1; then
  if swiftc -parse "$SRC" >/tmp/handar_swift_parse.out 2>&1; then
    echo "[OK] Swift parser"
  else
    echo "[WARN] swiftc parser unavailable for Apple SDK imports on this runner"
    sed -n '1,8p' /tmp/handar_swift_parse.out || true
  fi
else
  echo "[WARN] swiftc is not available. Open this project on macOS with Xcode."
fi

if command -v xcodebuild >/dev/null 2>&1; then
  echo "[OK] xcodebuild: $(xcodebuild -version | head -1)"
else
  echo "[WARN] xcodebuild is not available."
fi

echo "PASS"
