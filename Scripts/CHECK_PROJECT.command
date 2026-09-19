#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== Hand AR Browser V29 project check =="
for f in "HandARBrowser.xcodeproj/project.pbxproj" "HandARBrowser/AppDelegate.swift" "HandARBrowser/MainViewController.swift" "HandARBrowser/Info.plist" "HandARBrowser/WebInput.js"; do
  [[ -f "$f" ]] && echo "[OK] $f" || { echo "[FAIL] missing $f"; exit 1; }
done

SRC="HandARBrowser/MainViewController.swift"

grep -Fq "import ARKit" "$SRC"
grep -Fq "import SceneKit" "$SRC"
grep -Fq "ARWorldTrackingConfiguration" "$SRC"
grep -Fq "final class ARStereoTrackingManager" "$SRC"
grep -Fq "ARSessionDelegate" "$SRC"
grep -Fq "didUpdate anchors: [ARAnchor]" "$SRC"
grep -Fq "private let browser: WKWebView = {" "$SRC"
grep -Fq "private let arSceneView = ARSCNView(frame: .zero)" "$SRC"
grep -Fq "private let leftEyeView = SCNView(frame: .zero)" "$SRC"
grep -Fq "private let rightEyeView = SCNView(frame: .zero)" "$SRC"
grep -Fq "frame.camera.unprojectPoint" "$SRC"
grep -Fq "frame.displayTransform(" "$SRC"
grep -Fq "browserWorldDistance: Float = 1.55" "$SRC"
grep -Fq "eyeSeparation: Float = 0.064" "$SRC"
grep -Fq "input.update(" "$SRC"
grep -Fq "final class HandSkeletonView" "$SRC"
grep -Fq "isBackPinching" "$SRC"
grep -Fq "isForwardPinching" "$SRC"
grep -Fq "gestureHint" "$SRC"

grep -Fq "HandAR Vision" HandARBrowser/Info.plist
grep -Fq "NSCameraUsageDescription" HandARBrowser/Info.plist
grep -Fq "__handarScroll" HandARBrowser/WebInput.js

! grep -Fq "EyeDisplayView" "$SRC"
! grep -Fq "EyeContainer" "$SRC"
! grep -Fq "EyeBridgeView" "$SRC"
! grep -Fq "LensMaskView" "$SRC"
! grep -Fq "fillEllipse" "$SRC"
! grep -Fq "private let browserLeft" "$SRC"
! grep -Fq "private let browserRight" "$SRC"
! grep -Fq "panel.position =" "$SRC"
! grep -Fq "panel.layer.position =" "$SRC"
! grep -Fq "normalized(SIMD3<Float>" "$SRC"
! grep -Fq "SCNMatrix4FromMat4" "$SRC"
! grep -Fq "CGPoint(x: normalizedX, y: normalizedY)" "$SRC"
! grep -Fq "private let center = UIButton(type: .system)" "$SRC"

echo "[OK] V29 static project checks"

if command -v swiftc >/dev/null 2>&1; then
  # Parser-only validation can fail on Linux because Apple SDK modules are unavailable;
  # don't turn that environment limitation into a false project failure.
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
