# V19 architecture

V19 uses RealityKit ARView with a manually run ARWorldTrackingConfiguration. The browser is represented by synchronized left/right WKWebViews, but its virtual plane is anchored in AR world coordinates and projected into the camera every frame with ARCamera.projectPoint.

# Sources

Apple ARKit — ARWorldTrackingConfiguration:
https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration

Apple ARKit — ARCamera projection:
https://developer.apple.com/documentation/arkit/arcamera

Apple Vision — VNHumanHandPoseObservation:
https://developer.apple.com/documentation/vision/vnhumanhandposeobservation

Apple Vision — Detecting Hand Poses with Vision:
https://developer.apple.com/documentation/vision/detecting-hand-poses-with-vision

Apple WebKit — WKWebView:
https://developer.apple.com/documentation/webkit/wkwebview

The app uses these built-in frameworks rather than third-party SDKs.
