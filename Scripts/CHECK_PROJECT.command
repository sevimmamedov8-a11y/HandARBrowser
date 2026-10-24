#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
echo "== Hand AR Browser V102 project check =="
python3 Tests/check_project_paths.py
for f in "HandARBrowser.xcodeproj/project.pbxproj" "HandARBrowser/AppDelegate.swift" "HandARBrowser/MainViewController.swift" "HandARBrowser/HandGesture.swift" "HandARBrowser/CinemaHall.swift" "HandARBrowser/CinemaPlayback.swift" "HandARBrowser/Info.plist" "HandARBrowser/WebInput.js"; do
  [[ -f "$f" ]] && echo "[OK] $f" || { echo "[FAIL] missing $f"; exit 1; }
done

grep -Fq "final class CinemaHall" "HandARBrowser/CinemaHall.swift"
[[ -f "HandARBrowser/HandSilhouette.swift" ]]
[[ -f "HandARBrowser/CameraCapture.swift" ]]
[[ -f "HandARBrowser/CameraGeometry.swift" ]]
[[ -f "HandARBrowser/OfflinePanorama.swift" ]]
[[ -f "HandARBrowser/GraffitiStudio.swift" ]]
[[ -f "HandARBrowser/GraffitiState.swift" ]]
[[ -f "HandARBrowser/GraffitiRoomSave.swift" ]]
[[ -f "HandARBrowser/GraffitiProps.swift" ]]
[[ -f "HandARBrowser/GraffitiAudio.swift" ]]
[[ -f "HandARBrowser/GraffitiPhysics.swift" ]]
[[ -f "HandARBrowser/GraffitiRadio.swift" ]]
[[ -f "HandARBrowser/GraffitiMusic/credits.json" ]]
[[ -f "HandARBrowser/GraffitiSounds/spray.wav" ]]
[[ -f "HandARBrowser/VirtualHands.swift" ]]
[[ -f "HandARBrowser/Panoramas/catalog.json" ]]
[[ -f "HandARBrowser/Panoramas/burj-khalifa-night.jpg" ]]
[[ -f "HandARBrowser/TimeMotionLogic.swift" ]]
[[ -f "HandARBrowser/TimeMotionGame.swift" ]]
[[ -f "HandARBrowser/TimeMotionSounds/tm_shot.wav" ]]

SRC="HandARBrowser/MainViewController.swift"

# --- Time Motion integration (separate game, SecurityVRGame untouched) ---
grep -Fq "final class TimeMotionVRGame" "HandARBrowser/TimeMotionGame.swift"
grep -Fq "startTimeMotionVR()" "$SRC"
grep -Fq "case \"time-motion-game\":" "$SRC"
grep -Fq "tickTimeMotion(at: CACurrentMediaTime())" "$SRC"
grep -Fq "timeMotion.cancelInput()" "$SRC"
grep -Fq "final class SecurityVRGame" "HandARBrowser/SecurityVRGame.swift"

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
grep -Fq "MonoViewGeometry.lensCenter(eye:eye" "$SRC"
grep -Fq "return SIMD2(Float(center.x),Float(center.y))" "$SRC"
grep -Fq "final class VRCompositor" "$SRC"
grep -Fq "device.makeLibrary(source: VRCompositor.source, options: nil)" "$SRC"
grep -Fq "vr_fragment" "$SRC"
grep -Fq "ycbcr_to_rgb" "$SRC"
grep -Fq "MTKViewDelegate" "$SRC"
grep -Fq "SCNRenderer(device: metalDevice, options: nil)" "$SRC"
grep -Fq "CVMetalTextureCacheCreateTextureFromImage" "$SRC"

# --- one scene and one camera copied into both lens outputs ---
grep -Fq "private let worldScene = SCNScene()" "$SRC"
grep -Fq "private let headNode = SCNNode()" "$SRC"
grep -Fq "headNode.addChildNode(leftCameraNode)" "$SRC"
grep -Fq "leftCameraNode.simdPosition = .zero" "$SRC"
grep -Fq "float2 off = float2(0.0)" "$SRC"
! grep -Fq "rightRenderer.render(" "$SRC"
! grep -Fq "directVideoRight" "$SRC"
[[ -f "HandARBrowser/LensCalibration.swift" ]]
grep -Fq "browserWorldDistance: Float = 2.15" "$SRC"

# --- video remains in a spatial window; the hall is opened explicitly ---
grep -Fq "private static let cinemaPanelWidth" "$SRC"
grep -Fq "private static let cinemaPanelHeight" "$SRC"
grep -Fq "func setCinemaMode(_ active: Bool)" "$SRC"
grep -Fq "func resetPanelToDefaultSizeInstantly()" "$SRC"
grep -Fq "extension MainViewController: WKScriptMessageHandler" "$SRC"
grep -Fq "userContentController.add(WeakScriptMessageHandler(self), name: \"handarVideo\")" "$SRC"
grep -Fq "removeScriptMessageHandler(forName: \"handarVideo\")" "$SRC"
grep -Fq "struct VRPerformanceBudget" "$SRC"
grep -Fq "scheduleBrowserCapture()" "$SRC"

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
grep -Fq "queueHandForegroundMask(left:freshLeft,right:freshRight)" "$SRC"
grep -Fq "handMaskEnabled" "$SRC"
grep -Fq "handMaskTexture" "$SRC"
grep -Fq "texture2d<float> handMask" "$SRC"
grep -Fq "syncHandMaskTexture()" "$SRC"
grep -Fq "readsFromDepthBuffer = false" "$SRC"
! grep -Fq "leftHandSkeletonNode.isHidden = !visible" "$SRC"
! grep -Fq "rightHandSkeletonNode.isHidden = !visible" "$SRC"
grep -Fq "private func planeHit(" "$SRC"
grep -Fq "private func updateDrag(with ray: WorldRay)" "$SRC"
grep -Fq "if sample.isFist" "$SRC"
grep -Fq "struct StablePinchGesture" "HandARBrowser/HandGesture.swift"
grep -Fq "struct ReleaseClickGate" "HandARBrowser/HandGesture.swift"
grep -Fq "private static let defaultPanelWidth: Float = 2.90" "$SRC"
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
grep -Fq "uniforms.rClip = 10" "$SRC"

# --- V50 VR desktop + internal VR apps ---
grep -Fq "private static let vrDesktopHTML" "$SRC"
grep -Fq "handarApp" "$SRC"
grep -Fq "case \"youtube\"" "$SRC"
grep -Fq "case \"telegram\"" "$SRC"
grep -Fq "case \"notes\"" "$SRC"
grep -Fq "case \"calculator\"" "$SRC"
grep -Fq "final class VRBoxControllerService" "$SRC"
grep -Fq "final class VRBoxDiagnosticsView" "$SRC"
grep -Fq "import GameController" "$SRC"
grep -Fq "controller.onStick" "$SRC"
grep -Fq "private let controllerHandRoot = SCNNode()" "$SRC"
grep -Fq "GCSupportsControllerUserInteraction" "HandARBrowser/Info.plist"
grep -Fq 'data-id="photos"' "$SRC"
grep -Fq 'data-id="files"' "$SRC"
grep -Fq 'data-id="messages"' "$SRC"
grep -Fq 'data-id="phone"' "$SRC"
grep -Fq 'private static let vrPhotosHTML' "$SRC"
grep -Fq 'private static let vrFilesHTML' "$SRC"
grep -Fq 'private static let vrMessagesHTML' "$SRC"
grep -Fq 'private static let vrPhoneHTML' "$SRC"

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
! grep -Fq "final class LensMaskView" "$SRC"
! grep -Fq "private let browserLeft" "$SRC"
! grep -Fq "private let browserRight" "$SRC"
! grep -Fq "browserPlaneForUnprojection" "$SRC"
! grep -Fq "let isPinching: Bool" "$SRC"
! grep -Fq "cursorNode" "$SRC"

# V75 spatial Home View and common app shell.
grep -Fq 'class="rail glass"' "$SRC"
grep -Fq 'class="window-ornament"' "$SRC"
grep -Fq 'class="spatial-sidebar"' "$SRC"
grep -Fq 'applySpatialSurface(home: true, transparent: true)' "$SRC"
grep -Fq 'case "environment-camera", "environment-dark"' "$SRC"
grep -Fq 'handar-hover' "$JS"

echo "[OK] V92 static project checks"

if command -v swiftc >/dev/null 2>&1; then
  # Parser-only validation can fail on Linux because Apple SDK modules are unavailable;
  # don't turn that environment limitation into a false project failure.
  if swiftc -parse HandARBrowser/*.swift >/tmp/handar_swift_parse.out 2>&1; then
    echo "[OK] Swift parser"
  else
    cat /tmp/handar_swift_parse.out
    exit 1
  fi
else
  echo "[WARN] swiftc is not available. Open this project on macOS with Xcode."
fi

if command -v xcodebuild >/dev/null 2>&1; then
  echo "[OK] xcodebuild: $(xcodebuild -version 2>/dev/null | sed -n '1p')"
else
  echo "[WARN] xcodebuild is not available."
fi

echo "PASS"
