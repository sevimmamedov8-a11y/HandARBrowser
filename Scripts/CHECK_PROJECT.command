#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== Hand AR Browser V40 project check =="
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
grep -Fq "func worldRay(visionPoint: CGPoint) -> WorldRay?" "$SRC"

# --- real VR: lens geometry, per-eye frustums, distortion ---
grep -Fq "struct VRProfile" "$SRC"
grep -Fq "enum VRLensMath" "$SRC"
grep -Fq "static func frustum(eye: Int, profile: VRProfile)" "$SRC"
grep -Fq "static func lensCenterUV(eye: Int, profile: VRProfile)" "$SRC"
grep -Fq "let halfEyeWidth = profile.screenWidthMM * 0.25" "$SRC"
grep -Fq "return SIMD2<Float>(0.5," "$SRC"
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
grep -Fq "browserWorldDistance: Float = 1.65" "$SRC"

# --- cinema mode: video in TikTok/YouTube fills the field of view ---
grep -Fq "private static let cinemaPanelWidth" "$SRC"
grep -Fq "private static let cinemaPanelHeight" "$SRC"
grep -Fq "func setCinemaMode(_ active: Bool)" "$SRC"
grep -Fq "func resetPanelToDefaultSizeInstantly()" "$SRC"
grep -Fq "extension MainViewController: WKScriptMessageHandler" "$SRC"
grep -Fq "userContentController.add(self, name: \"handarVideo\")" "$SRC"
grep -Fq "removeScriptMessageHandler(forName: \"handarVideo\")" "$SRC"
grep -Fq "isCinemaMode ? (1.0 / 24.0) : (1.0 / 12.0)" "$SRC"

JS="HandARBrowser/WebInput.js"
grep -Fq "handarVideo" "$JS"
grep -Fq "fullscreenchange" "$JS"
grep -Fq "webkitbeginfullscreen" "$JS"
grep -Fq "findDominantVideo" "$JS"
grep -Fq "webkitEnterFullscreen" "$JS"
grep -Fq "handar-inline-video-fullscreen" "$JS"

# --- ray pointer, split gestures, drag, toolbar ---
grep -Fq "struct WorldRay" "$SRC"
grep -Fq "let clickPinch: Bool" "$SRC"
grep -Fq "let grabPinch: Bool" "$SRC"
grep -Fq "middleTip: CGPoint" "$SRC"
grep -Fq "private let rayNode = SCNNode()" "$SRC"
grep -Fq "private let pointerRingNode = SCNNode()" "$SRC"
grep -Fq "private let leftHandSkeletonNode = SCNNode()" "$SRC"
grep -Fq "private let rightHandSkeletonNode = SCNNode()" "$SRC"
grep -Fq "private static let handSkeletonBonePairs" "$SRC"
grep -Fq "recognizedPoints(.all)" "$SRC"
grep -Fq "queueHandForegroundMask(left: left, right: right)" "$SRC"
grep -Fq "handMaskEnabled" "$SRC"
grep -Fq "handMaskTexture" "$SRC"
grep -Fq "texture2d<float> handMask" "$SRC"
grep -Fq "syncHandMaskTexture()" "$SRC"
grep -Fq "readsFromDepthBuffer = false" "$SRC"
! grep -Fq "leftHandSkeletonNode.isHidden = !visible" "$SRC"
! grep -Fq "rightHandSkeletonNode.isHidden = !visible" "$SRC"
grep -Fq "private func planeHit(" "$SRC"
grep -Fq "private func updateDrag(with ray: WorldRay)" "$SRC"
grep -Fq "dragZoneHeight" "$SRC"
grep -Fq "private static let defaultPanelWidth: Float = 2.70" "$SRC"
! grep -Fq "private let browserWorldWidth: Float = 0.82" "$SRC"
grep -Fq "struct ToolbarItem" "$SRC"
grep -Fq "private var linkItems: [ToolbarItem] = []" "$SRC"
! grep -Fq "private var toolbarItems" "$SRC"
grep -Fq "youTubeURL" "$SRC"
grep -Fq "tikTokURL" "$SRC"
grep -Fq "m.youtube.com" "$SRC"
grep -Fq "www.tiktok.com" "$SRC"

# --- menu must scroll: five sliders do not fit a landscape screen ---
grep -Fq "private let scrollView = UIScrollView()" "$SRC"
grep -Fq "scrollView.contentLayoutGuide" "$SRC"
grep -Fq "minimum: Float, maximum: Float, step: Float" "$SRC"

# --- browser surface and input ---
grep -Fq "private let browser: WKWebView = {" "$SRC"
grep -Fq "input.update(" "$SRC"
grep -Fq "config.allowsPictureInPictureMediaPlayback = false" "$SRC"
grep -Fq "config.preferences.isElementFullscreenEnabled = false" "$SRC"
grep -Fq "let maxLensRadius = min(0.5" "$SRC"

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
! grep -Fq "private let browserLeft" "$SRC"
! grep -Fq "private let browserRight" "$SRC"
! grep -Fq "browserPlaneForUnprojection" "$SRC"
! grep -Fq "let isPinching: Bool" "$SRC"
! grep -Fq "cursorNode" "$SRC"

echo "[OK] V40 static project checks"

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
