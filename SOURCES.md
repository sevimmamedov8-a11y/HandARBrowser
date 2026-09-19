# V18 architecture

V18 uses RealityKit ARView with a manually run ARWorldTrackingConfiguration. ARSession frames feed Vision hand tracking, while the browser is rendered as synchronized left/right WKWebViews over the live camera background.

# Sources

Apple Vision — VNHumanHandPoseObservation / chirality:
https://developer.apple.com/documentation/vision/vnhumanhandposeobservation

Apple Vision — Detecting Hand Poses with Vision:
https://developer.apple.com/documentation/vision/detecting-hand-poses-with-vision

Apple ARKit / RealityKit — CMMotionManager:
https://developer.apple.com/documentation/coremotion/cmmotionmanager

Apple ARKit / RealityKit — processed device-motion data:
https://developer.apple.com/documentation/coremotion/getting-processed-device-motion-data

Apple WebKit — WKWebView:
https://developer.apple.com/documentation/webkit/wkwebview

The app uses these built-in frameworks rather than third-party SDKs.
