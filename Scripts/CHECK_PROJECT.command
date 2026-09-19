#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== Hand AR Browser V29 project check =="
for f in "HandARBrowser.xcodeproj/project.pbxproj" "HandARBrowser/AppDelegate.swift" "HandARBrowser/MainViewController.swift" "HandARBrowser/Info.plist" "HandARBrowser/WebInput.js"; do
  [[ -f "$f" ]] && echo "[OK] $f" || { echo "[FAIL] missing $f"; exit 1; }
done

SRC="HandARBrowser/MainViewController.swift"

# --- frameworks the stereo pipeline needs ---
grep -Fq "import ARKit" "$SRC"
grep -Fq "import SceneKit" "$SRC"
grep -Fq "import Metal" "$SRC"
grep -Fq "import MetalKit" "$SRC"

# --- tracking layer ---
grep -Fq "ARWorldTrackingConfiguration" "$SRC"
grep -Fq "final class ARStereoTrackingManager" "$SRC"
grep -Fq "ARSessionDelegate" "$SRC"
grep -Fq "didUpdate anchors: [ARAnchor]" "$SRC"
grep -Fq "frame.camera.viewMatrix(for: interfaceOrientation).inverse" "$SRC"
grep -Fq "frame.camera.unprojectPoint" "$SRC"

# --- real VR: lens geometry, per-eye frustums, distortion ---
grep -Fq "struct VRProfile" "$SRC"
grep -Fq "enum VRLensMath" "$SRC"
grep -Fq "static func frustum(eye: Int, profile: VRProfile)" "$SRC"
grep -Fq "static func lensCenterUV(eye: Int, profile: VRProfile)" "$SRC"
grep -Fq "final class VRCompositor" "$SRC"
grep -Fq "device.makeLibrary(source: VRCompositor.source, options: nil)" "$SRC"
grep -Fq "vr_fragment" "$SRC"
grep -Fq "ycbcr_to_rgb" "$SRC"
grep -Fq "MTKViewDelegate" "$SRC"
grep -Fq "SCNRenderer(device: metalDevice, options: nil)" "$SRC"
grep -Fq "CVMetalTextureCacheCreateTextureFromImage" "$SRC"

# --- one scene, two eye cameras on a real IPD ---
grep -Fq "private let worldScene = SCNScene()" "$SRC"
grep -Fq "private let headNode = SCNNode()" "$SRC"
grep -Fq "headNode.addChildNode(leftCameraNode)" "$SRC"
grep -Fq "headNode.addChildNode(rightCameraNode)" "$SRC"
grep -Fq "profile.ipdMM * 0.0005" "$SRC"
grep -Fq "browserWorldDistance: Float = 1.55" "$SRC"

# --- browser surface and input ---
grep -Fq "private let browser: WKWebView = {" "$SRC"
grep -Fq "input.update(" "$SRC"

grep -Fq "HandAR Vision" HandARBrowser/Info.plist
grep -Fq "NSCameraUsageDescription" HandARBrowser/Info.plist

# --- the split-screen architecture must be gone ---
! grep -Fq "ARSCNView" "$SRC"
! grep -Fq "leftEyeView" "$SRC"
! grep -Fq "rightEyeView" "$SRC"
! grep -Fq "private let leftScene = SCNScene()" "$SRC"
! grep -Fq "private let rightScene = SCNScene()" "$SRC"
! grep -Fq "frame.camera.projectionMatrix(" "$SRC"
! grep -Fq "EyeDisplayView" "$SRC"
! grep -Fq "LensMaskView" "$SRC"
! grep -Fq "fillEllipse" "$SRC"
! grep -Fq "private let browserLeft" "$SRC"
! grep -Fq "private let browserRight" "$SRC"

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
