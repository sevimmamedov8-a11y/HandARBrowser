import UIKit
import AVFoundation
import ARKit
import SceneKit
import Vision
import WebKit
import simd

struct HandSample {
    let indexTip: CGPoint
    let thumbTip: CGPoint
    let isPinching: Bool
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
}

final class MainViewController: UIViewController {
    private let tracking = ARStereoTrackingManager()
    private let hands = HandTracker()
    private let input = WebInputBridge()

    // One browser instance per eye. Both are synchronized by the same hand input.
    private let leftBrowser: WKWebView = MainViewController.makeBrowser()
    private let rightBrowser: WKWebView = MainViewController.makeBrowser()
    private var browserTimer: Timer?
    private var leftSnapshotBusy = false
    private var rightSnapshotBusy = false

    // AR camera passthrough behind the two VR eye windows.
    private let arSceneView = ARSCNView(frame: .zero)

    // Two independent square eye viewports. Each gets its own SceneKit camera.
    private let leftEyeView = SCNView(frame: .zero)
    private let rightEyeView = SCNView(frame: .zero)
    private let leftScene = SCNScene()
    private let rightScene = SCNScene()
    private let leftPlaneNode = SCNNode()
    private let rightPlaneNode = SCNNode()
    private let leftCursorNode = SCNNode()
    private let rightCursorNode = SCNNode()
    private let leftCameraNode = SCNNode()
    private let rightCameraNode = SCNNode()
    private let leftMaterial = SCNMaterial()
    private let rightMaterial = SCNMaterial()

    private let leftSkeleton = HandSkeletonView()
    private let rightSkeleton = HandSkeletonView()
    private let lensMask = StereoLensMaskView()
    private let menu = MainMenuView()

    private var inAR = false
    private var browserAnchor: ARAnchor?
    private var browserWorldTransform: simd_float4x4?
    private var lastCenterGestureTime: CFTimeInterval = 0
    private var didCreateInitialAnchor = false

    // Spatial browser dimensions in meters.
    private let browserWorldWidth: Float = 0.72
    private let browserWorldHeight: Float = 0.43
    private let browserWorldDistance: Float = 1.65
    private let eyeSeparation: Float = 0.064

    override var prefersStatusBarHidden: Bool { true }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        [.landscapeLeft, .landscapeRight]
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }
    override var prefersHomeIndicatorAutoHidden: Bool { inAR }

    private static let homeURL = URL(string: "https://www.google.com/")!

    override func viewDidLoad() {
        super.viewDidLoad()
        configureBrowsers()
        configureScenes()
        buildInterface()
        wireServices()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestLandscapeMode()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutViews()
        tracking.setInterfaceOrientation(currentInterfaceOrientation())
        updateEyeCameras()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            guard let self else { return }
            self.tracking.setInterfaceOrientation(self.currentInterfaceOrientation())
            self.layoutViews()
        }) { [weak self] _ in
            guard let self else { return }
            self.tracking.setInterfaceOrientation(self.currentInterfaceOrientation())
            self.layoutViews()
            self.updateEyeCameras()
        }
    }

    deinit {
        browserTimer?.invalidate()
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }

    private static func makeBrowser() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        if let path = Bundle.main.path(forResource: "WebInput", ofType: "js"),
           let js = try? String(contentsOfFile: path, encoding: .utf8) {
            controller.addUserScript(
                WKUserScript(
                    source: js,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }
        config.userContentController = controller

        let webView = WKWebView(frame: CGRect(x: -2000, y: -2000, width: 960, height: 600), configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.alwaysBounceVertical = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        return webView
    }

    private func configureBrowsers() {
        leftBrowser.navigationDelegate = self
        leftBrowser.uiDelegate = self
        rightBrowser.navigationDelegate = self
        rightBrowser.uiDelegate = self

        leftBrowser.load(URLRequest(url: Self.homeURL))
        rightBrowser.load(URLRequest(url: Self.homeURL))
    }

    private func buildInterface() {
        view.backgroundColor = .black

        arSceneView.session = tracking.session
        arSceneView.scene = SCNScene()
        arSceneView.backgroundColor = .black
        arSceneView.isOpaque = true
        arSceneView.clipsToBounds = true
        arSceneView.autoenablesDefaultLighting = false
        arSceneView.rendersCameraGrain = false
        arSceneView.rendersMotionBlur = false
        arSceneView.isUserInteractionEnabled = false
        view.addSubview(arSceneView)

        leftEyeView.isOpaque = false
        leftEyeView.backgroundColor = .clear
        leftEyeView.scene = leftScene
        leftEyeView.pointOfView = leftCameraNode
        leftEyeView.autoenablesDefaultLighting = false
        leftEyeView.allowsCameraControl = false
        leftEyeView.rendersContinuously = true
        leftEyeView.isPlaying = true
        leftEyeView.isUserInteractionEnabled = false
        view.addSubview(leftEyeView)

        rightEyeView.isOpaque = false
        rightEyeView.backgroundColor = .clear
        rightEyeView.scene = rightScene
        rightEyeView.pointOfView = rightCameraNode
        rightEyeView.autoenablesDefaultLighting = false
        rightEyeView.allowsCameraControl = false
        rightEyeView.rendersContinuously = true
        rightEyeView.isPlaying = true
        rightEyeView.isUserInteractionEnabled = false
        view.addSubview(rightEyeView)

        leftSkeleton.isUserInteractionEnabled = false
        rightSkeleton.isUserInteractionEnabled = false
        leftEyeView.addSubview(leftSkeleton)
        rightEyeView.addSubview(rightSkeleton)

        view.addSubview(lensMask)
        view.addSubview(leftBrowser)
        view.addSubview(rightBrowser)
        view.addSubview(menu)
        setARVisible(false)
    }

    private func layoutViews() {
        let bounds = view.bounds
        arSceneView.frame = bounds

        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 10
        let gap: CGFloat = 10
        let halfWidth = (bounds.width - horizontalPadding * 2 - gap) * 0.5
        let side = max(1, min(halfWidth, bounds.height - verticalPadding * 2))
        let total = side * 2 + gap
        let startX = (bounds.width - total) * 0.5
        let startY = (bounds.height - side) * 0.5

        let leftRect = CGRect(x: startX, y: startY, width: side, height: side)
        let rightRect = CGRect(x: startX + side + gap, y: startY, width: side, height: side)

        leftEyeView.frame = leftRect
        rightEyeView.frame = rightRect
        leftSkeleton.frame = leftEyeView.bounds
        rightSkeleton.frame = rightEyeView.bounds
        lensMask.leftRect = leftRect
        lensMask.rightRect = rightRect
        lensMask.setNeedsLayout()

        // Hidden browser render surfaces stay alive and render at a stable aspect ratio.
        leftBrowser.frame = CGRect(x: -2000, y: -2000, width: 960, height: 600)
        rightBrowser.frame = CGRect(x: -2000, y: -2700, width: 960, height: 600)
        menu.frame = bounds
    }

    private var leftLensRect: CGRect { lensMask.leftRect }
    private var rightLensRect: CGRect { lensMask.rightRect }

    private func configureScenes() {
        configureEyeScene(leftScene, planeNode: leftPlaneNode, cursorNode: leftCursorNode, material: leftMaterial)
        configureEyeScene(rightScene, planeNode: rightPlaneNode, cursorNode: rightCursorNode, material: rightMaterial)

        let leftCamera = SCNCamera()
        leftCamera.zNear = 0.01
        leftCamera.zFar = 100.0
        leftCameraNode.camera = leftCamera

        let rightCamera = SCNCamera()
        rightCamera.zNear = 0.01
        rightCamera.zFar = 100.0
        rightCameraNode.camera = rightCamera

        leftScene.rootNode.addChildNode(leftCameraNode)
        rightScene.rootNode.addChildNode(rightCameraNode)
    }

    private func configureEyeScene(
        _ scene: SCNScene,
        planeNode: SCNNode,
        cursorNode: SCNNode,
        material: SCNMaterial
    ) {
        scene.background.contents = UIColor.clear
        scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }

        let geometry = SCNPlane(
            width: CGFloat(browserWorldWidth),
            height: CGFloat(browserWorldHeight)
        )
        geometry.firstMaterial = material
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.black
        material.emission.contents = UIColor.black
        material.specular.contents = UIColor.black
        material.shininess = 0
        planeNode.geometry = geometry
        scene.rootNode.addChildNode(planeNode)

        let cursorGeometry = SCNCylinder(radius: 0.008, height: 0.002)
        cursorGeometry.radialSegmentCount = 16
        let cursorMaterial = SCNMaterial()
        cursorMaterial.lightingModel = .constant
        cursorMaterial.diffuse.contents = UIColor.white
        cursorMaterial.emission.contents = UIColor.white
        cursorGeometry.firstMaterial = cursorMaterial
        cursorNode.geometry = cursorGeometry
        cursorNode.eulerAngles = SCNVector3(Float.pi * 0.5, 0, 0)
        cursorNode.isHidden = true
        scene.rootNode.addChildNode(cursorNode)
    }

    private func wireServices() {
        tracking.onFrame = { [weak self] pixelBuffer, orientation in
            self?.hands.process(pixelBuffer: pixelBuffer, orientation: orientation)
        }

        tracking.onCamera = { [weak self] frame in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.inAR else { return }
                self.ensureBrowserAnchor(using: frame.camera.transform)
                self.updateEyeCameras(using: frame)
            }
        }

        tracking.onAnchorUpdate = { [weak self] anchor in
            guard let self else { return }
            guard let browserAnchor = self.browserAnchor,
                  anchor.identifier == browserAnchor.identifier else { return }
            DispatchQueue.main.async {
                self.browserWorldTransform = anchor.transform
                self.applyBrowserWorldTransform()
            }
        }

        tracking.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.leaveARToMenu()
                self?.showAlert(message)
            }
        }

        hands.onUpdate = { [weak self] left, right in
            DispatchQueue.main.async {
                self?.handleHands(left: left, right: right)
            }
        }

        browserTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.updateBrowserSnapshots()
        }
    }

    private func requestCameraAndEnterAR() {
        guard !inAR else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            showAlert("Этот iPhone не поддерживает ARKit World Tracking.")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            enterAR()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if allowed {
                        self.enterAR()
                    } else {
                        self.showAlert("Нужен доступ к задней камере для AR.")
                    }
                }
            }
        case .denied, .restricted:
            showAlert("Разреши камеру в Настройки → HandAR Vision → Камера.")
        @unknown default:
            showAlert("Не удалось проверить доступ к камере.")
        }
    }

    private func enterAR() {
        guard !inAR else { return }
        inAR = true
        lastCenterGestureTime = 0
        didCreateInitialAnchor = false
        browserAnchor = nil
        browserWorldTransform = nil

        requestLandscapeMode()
        setARVisible(true)
        tracking.setInterfaceOrientation(currentInterfaceOrientation())
        tracking.start()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func setARVisible(_ visible: Bool) {
        arSceneView.isHidden = !visible
        leftEyeView.isHidden = !visible
        rightEyeView.isHidden = !visible
        leftSkeleton.isHidden = !visible
        rightSkeleton.isHidden = !visible
        lensMask.isHidden = !visible
        menu.isHidden = visible
        menu.isUserInteractionEnabled = !visible
        leftCursorNode.isHidden = true
        rightCursorNode.isHidden = true
    }

    private func leaveARToMenu() {
        tracking.pause()
        if let anchor = browserAnchor {
            tracking.remove(anchor: anchor)
        }

        browserAnchor = nil
        browserWorldTransform = nil
        didCreateInitialAnchor = false
        inAR = false
        setARVisible(false)
        requestLandscapeMode()
    }

    private func requestLandscapeMode() {
        guard let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: [.landscapeLeft, .landscapeRight]),
            errorHandler: nil
        )
    }

    private func ensureBrowserAnchor(using cameraTransform: simd_float4x4) {
        guard inAR, !didCreateInitialAnchor else { return }
        guard view.bounds.width > view.bounds.height, leftLensRect.width > 10 else { return }

        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let forward = simd_normalize(SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        ))

        var transform = matrix_identity_float4x4
        transform.columns.0 = cameraTransform.columns.0
        transform.columns.1 = cameraTransform.columns.1
        transform.columns.2 = cameraTransform.columns.2
        transform.columns.3 = SIMD4<Float>(cameraPosition + forward * browserWorldDistance, 1)

        let anchor = ARAnchor(name: "HandAR_Stereo_Browser", transform: transform)
        browserAnchor = anchor
        browserWorldTransform = transform
        didCreateInitialAnchor = true
        tracking.add(anchor: anchor)
        applyBrowserWorldTransform()
    }

    private func applyBrowserWorldTransform() {
        guard let transform = browserWorldTransform else { return }
        // The two eye surfaces occupy the same world plane. Stereo disparity comes from the two cameras.
        leftPlaneNode.simdWorldTransform = transform
        rightPlaneNode.simdWorldTransform = transform
    }

    private func updateEyeCameras(using frame: ARFrame? = nil) {
        guard let frame = frame ?? tracking.latestFrameCopy else { return }
        let leftSize = leftEyeView.bounds.size
        let rightSize = rightEyeView.bounds.size
        guard leftSize.width > 10, leftSize.height > 10, rightSize.width > 10, rightSize.height > 10 else { return }

        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        let rightAxis = simd_normalize(SIMD3<Float>(
            frame.camera.transform.columns.0.x,
            frame.camera.transform.columns.0.y,
            frame.camera.transform.columns.0.z
        ))

        var leftTransform = frame.camera.transform
        var rightTransform = frame.camera.transform
        leftTransform.columns.3 = SIMD4<Float>(cameraPosition - rightAxis * (eyeSeparation * 0.5), 1)
        rightTransform.columns.3 = SIMD4<Float>(cameraPosition + rightAxis * (eyeSeparation * 0.5), 1)
        leftCameraNode.simdWorldTransform = leftTransform
        rightCameraNode.simdWorldTransform = rightTransform

        let leftProjection = frame.camera.projectionMatrix(
            for: currentInterfaceOrientation(),
            viewportSize: leftSize,
            zNear: 0.01,
            zFar: 100
        )
        let rightProjection = frame.camera.projectionMatrix(
            for: currentInterfaceOrientation(),
            viewportSize: rightSize,
            zNear: 0.01,
            zFar: 100
        )

        leftCameraNode.camera?.projectionTransform = SCNMatrix4(leftProjection)
        rightCameraNode.camera?.projectionTransform = SCNMatrix4(rightProjection)
    }

    private func updateBrowserSnapshots() {
        guard inAR else { return }
        updateLeftSnapshot()
        updateRightSnapshot()
    }

    private func updateLeftSnapshot() {
        guard !leftSnapshotBusy else { return }
        leftSnapshotBusy = true
        let configuration = WKSnapshotConfiguration()
        configuration.rect = leftBrowser.bounds
        leftBrowser.takeSnapshot(with: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.leftSnapshotBusy = false
                guard let image else { return }
                self.leftMaterial.diffuse.contents = image
                self.leftMaterial.emission.contents = image
            }
        }
    }

    private func updateRightSnapshot() {
        guard !rightSnapshotBusy else { return }
        rightSnapshotBusy = true
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rightBrowser.bounds
        rightBrowser.takeSnapshot(with: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rightSnapshotBusy = false
                guard let image else { return }
                self.rightMaterial.diffuse.contents = image
                self.rightMaterial.emission.contents = image
            }
        }
    }

    private func handleHands(left: HandSample?, right: HandSample?) {
        guard inAR else { return }

        leftSkeleton.update(hand: left, mapper: { [weak self] point in
            self?.tracking.screenPoint(forVisionPoint: CGPoint(x: point.x, y: 1 - point.y), viewportSize: self?.leftEyeView.bounds.size ?? .zero)
        })
        rightSkeleton.update(hand: right, mapper: { [weak self] point in
            self?.tracking.screenPoint(forVisionPoint: CGPoint(x: point.x, y: 1 - point.y), viewportSize: self?.rightEyeView.bounds.size ?? .zero)
        })

        if left?.isPinching == true && right?.isPinching == true {
            let now = CACurrentMediaTime()
            if now - lastCenterGestureTime > 1.0 {
                lastCenterGestureTime = now
                resetBrowserAnchor()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            releasePointers()
            hideCursors()
            return
        }

        guard let sample = right ?? left else {
            releasePointers()
            hideCursors()
            return
        }

        guard let fullPoint = tracking.screenPoint(
            forVisionPoint: CGPoint(x: sample.indexTip.x, y: 1 - sample.indexTip.y),
            viewportSize: view.bounds.size
        ) else {
            releasePointers()
            hideCursors()
            return
        }

        let eye: EyeSide
        let eyeRect: CGRect
        if leftLensRect.contains(fullPoint) {
            eye = .left
            eyeRect = leftLensRect
        } else if rightLensRect.contains(fullPoint) {
            eye = .right
            eyeRect = rightLensRect
        } else {
            releasePointers()
            hideCursors()
            return
        }

        let localPoint = CGPoint(x: fullPoint.x - eyeRect.minX, y: fullPoint.y - eyeRect.minY)
        guard let worldPoint = tracking.worldPointOnBrowser(
            localPoint: localPoint,
            viewportSize: eyeRect.size,
            planeTransform: browserPlaneForUnprojection()
        ), let transform = browserWorldTransform else {
            releasePointers()
            hideCursors()
            return
        }

        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let rightAxis = simd_normalize(SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
        let upAxis = simd_normalize(SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
        let delta = worldPoint - center
        let localX = simd_dot(delta, rightAxis)
        let localY = simd_dot(delta, upAxis)
        let normalizedX = CGFloat(localX / browserWorldWidth + 0.5)
        let normalizedY = CGFloat(0.5 - localY / browserWorldHeight)

        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else {
            releasePointers()
            hideCursors()
            return
        }

        if eye == .left {
            leftCursorNode.simdWorldPosition = worldPoint
            leftCursorNode.isHidden = false
            rightCursorNode.isHidden = true
        } else {
            rightCursorNode.simdWorldPosition = worldPoint
            rightCursorNode.isHidden = false
            leftCursorNode.isHidden = true
        }

        input.update(
            normalizedPoint: CGPoint(x: normalizedX, y: normalizedY),
            pinch: sample.isPinching,
            leftWebView: leftBrowser,
            rightWebView: rightBrowser
        )
    }

    private enum EyeSide { case left, right }

    private func browserPlaneForUnprojection() -> simd_float4x4? {
        guard let transform = browserWorldTransform else { return nil }
        let right = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let up = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let normal = SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

        var result = matrix_identity_float4x4
        // ARCamera.unprojectPoint expects the plane in local XZ coordinates.
        result.columns.0 = SIMD4<Float>(right, 0)
        result.columns.1 = SIMD4<Float>(normal, 0)
        result.columns.2 = SIMD4<Float>(up, 0)
        result.columns.3 = SIMD4<Float>(center, 1)
        return result
    }

    private func resetBrowserAnchor() {
        if let anchor = browserAnchor {
            tracking.remove(anchor: anchor)
        }
        browserAnchor = nil
        browserWorldTransform = nil
        didCreateInitialAnchor = false
    }

    private func hideCursors() {
        leftCursorNode.isHidden = true
        rightCursorNode.isHidden = true
    }

    private func releasePointers() {
        input.release(leftWebView: leftBrowser, rightWebView: rightBrowser)
    }

    private func showAlert(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "HandAR Vision",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension MainViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateBrowserSnapshots()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

final class ARStereoTrackingManager: NSObject, ARSessionDelegate {
    let session = ARSession()
    private let frameLock = NSLock()
    private var latestFrame: ARFrame?
    private var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?
    var onCamera: ((ARFrame) -> Void)?
    var onAnchorUpdate: ((ARAnchor) -> Void)?
    var onFailure: ((String) -> Void)?

    var latestFrameCopy: ARFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        interfaceOrientation = orientation
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            onFailure?("Этот iPhone не поддерживает ARKit World Tracking.")
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }

        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
    }

    func add(anchor: ARAnchor) { session.add(anchor: anchor) }
    func remove(anchor: ARAnchor) { session.remove(anchor: anchor) }

    func screenPoint(forVisionPoint point: CGPoint, viewportSize: CGSize) -> CGPoint? {
        guard let frame = latestFrameCopy, viewportSize.width > 1, viewportSize.height > 1 else { return nil }
        let mapped = point.applying(
            frame.displayTransform(for: interfaceOrientation, viewportSize: viewportSize)
        )
        let result = CGPoint(
            x: mapped.x * viewportSize.width,
            y: mapped.y * viewportSize.height
        )
        guard result.x.isFinite, result.y.isFinite else { return nil }
        return result
    }

    func worldPointOnBrowser(
        localPoint: CGPoint,
        viewportSize: CGSize,
        planeTransform: simd_float4x4?
    ) -> SIMD3<Float>? {
        guard let frame = latestFrameCopy, let planeTransform, viewportSize.width > 1, viewportSize.height > 1 else { return nil }
        guard let point = frame.camera.unprojectPoint(
            localPoint,
            ontoPlane: planeTransform,
            orientation: interfaceOrientation,
            viewportSize: viewportSize
        ) else {
            return nil
        }
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        return point
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameLock.lock()
        latestFrame = frame
        frameLock.unlock()

        onFrame?(frame.capturedImage, imageOrientation(for: interfaceOrientation))
        onCamera?(frame)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        anchors.forEach { onAnchorUpdate?($0) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onFailure?("ARKit завершил сессию: \(error.localizedDescription)")
    }

    private func imageOrientation(for orientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .up
        }
    }
}

final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        if let latest = VNDetectHumanHandPoseRequest.supportedRevisions.max() {
            request.revision = latest
        }
        return request
    }()

    private let queue = DispatchQueue(label: "handar.vision", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)

    private var lastIndexLeft: CGPoint?
    private var lastIndexRight: CGPoint?
    private var lastThumbLeft: CGPoint?
    private var lastThumbRight: CGPoint?
    private var pinchLeft = false
    private var pinchRight = false

    var onUpdate: ((HandSample?, HandSample?) -> Void)?

    func process(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard gate.wait(timeout: .now()) == .success else { return }

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.gate.signal() }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([self.request])

                var left: HandSample?
                var right: HandSample?
                var foundLeft = false
                var foundRight = false

                for observation in self.request.results ?? [] {
                    guard let points = try? observation.recognizedPoints(.all) else { continue }
                    guard let index = points[.indexTip],
                          let thumb = points[.thumbTip],
                          let wrist = points[.wrist],
                          let middle = points[.middleMCP],
                          index.confidence > 0.66,
                          thumb.confidence > 0.60,
                          wrist.confidence > 0.45,
                          middle.confidence > 0.45 else { continue }

                    let isLeft = observation.chirality == .left
                    let oldIndex = isLeft ? self.lastIndexLeft : self.lastIndexRight
                    let oldThumb = isLeft ? self.lastThumbLeft : self.lastThumbRight

                    let filteredIndex = smooth(oldIndex, index.location, alpha: adaptiveAlpha(previous: oldIndex, current: index.location))
                    let filteredThumb = smooth(oldThumb, thumb.location, alpha: adaptiveAlpha(previous: oldThumb, current: thumb.location))

                    let palmSize = max(distance(wrist.location, middle.location), 0.03)
                    let ratio = distance(filteredIndex, filteredThumb) / palmSize
                    let wasPinching = isLeft ? self.pinchLeft : self.pinchRight
                    let pinching = pinchHysteresis(previous: wasPinching, ratio: ratio)

                    var filteredJoints: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
                    for (name, point) in points where point.confidence > 0.25 {
                        filteredJoints[name] = point.location
                    }
                    filteredJoints[.indexTip] = filteredIndex
                    filteredJoints[.thumbTip] = filteredThumb

                    let sample = HandSample(
                        indexTip: filteredIndex,
                        thumbTip: filteredThumb,
                        isPinching: pinching,
                        joints: filteredJoints
                    )

                    if isLeft {
                        self.lastIndexLeft = filteredIndex
                        self.lastThumbLeft = filteredThumb
                        self.pinchLeft = pinching
                        foundLeft = true
                        left = sample
                    } else {
                        self.lastIndexRight = filteredIndex
                        self.lastThumbRight = filteredThumb
                        self.pinchRight = pinching
                        foundRight = true
                        right = sample
                    }
                }

                if !foundLeft {
                    self.lastIndexLeft = nil
                    self.lastThumbLeft = nil
                    self.pinchLeft = false
                }
                if !foundRight {
                    self.lastIndexRight = nil
                    self.lastThumbRight = nil
                    self.pinchRight = false
                }

                self.onUpdate?(left, right)
            } catch {
                self.onUpdate?(nil, nil)
            }
        }
    }
}

@inline(__always)
private func smooth(_ old: CGPoint?, _ new: CGPoint, alpha: CGFloat) -> CGPoint {
    guard let old else { return new }
    return CGPoint(x: old.x + (new.x - old.x) * alpha, y: old.y + (new.y - old.y) * alpha)
}

@inline(__always)
private func adaptiveAlpha(previous: CGPoint?, current: CGPoint) -> CGFloat {
    guard let previous else { return 1.0 }
    let jump = min(distance(previous, current), 0.30)
    return min(0.84, max(0.22, 0.22 + jump * 2.1))
}

@inline(__always)
private func pinchHysteresis(previous: Bool, ratio: CGFloat) -> Bool {
    if previous { return ratio < 0.60 }
    return ratio < 0.43
}

@inline(__always)
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

final class WebInputBridge {
    private var lastPoint: CGPoint?
    private var pointerDown = false

    func update(
        normalizedPoint: CGPoint,
        pinch: Bool,
        leftWebView: WKWebView,
        rightWebView: WKWebView
    ) {
        let leftCurrent = CGPoint(
            x: normalizedPoint.x * leftWebView.bounds.width,
            y: normalizedPoint.y * leftWebView.bounds.height
        )
        let previous = lastPoint ?? leftCurrent
        let deltaY = leftCurrent.y - previous.y

        let event: String
        if pinch && !pointerDown {
            pointerDown = true
            event = "down"
        } else if pinch && pointerDown {
            event = abs(deltaY) > 0.75 ? "drag" : "move"
        } else if !pinch && pointerDown {
            pointerDown = false
            event = "up"
        } else {
            event = "hover"
        }

        for webView in [leftWebView, rightWebView] {
            let x = normalizedPoint.x * webView.bounds.width
            let y = normalizedPoint.y * webView.bounds.height
            switch event {
            case "down":
                dispatch("window.__handarPointerDown(\(x),\(y),1);", to: webView)
            case "drag":
                let amount = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), deltaY * 2.6)
                dispatch("window.scrollBy(0,\(amount));", to: webView)
                dispatch("window.__handarPointerMove(\(x),\(y),1);", to: webView)
            case "move":
                dispatch("window.__handarPointerMove(\(x),\(y),1);", to: webView)
            case "up":
                dispatch("window.__handarPointerUp(\(x),\(y),1);", to: webView)
            default:
                dispatch("window.__handarHover(\(x),\(y));", to: webView)
            }
        }

        lastPoint = leftCurrent
    }

    func release(leftWebView: WKWebView, rightWebView: WKWebView) {
        guard pointerDown else {
            lastPoint = nil
            return
        }
        pointerDown = false
        for webView in [leftWebView, rightWebView] {
            dispatch("window.__handarPointerUp(window.innerWidth/2,window.innerHeight/2,1);", to: webView)
        }
        lastPoint = nil
    }

    private func dispatch(_ script: String, to webView: WKWebView) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

final class HandSkeletonView: UIView {
    private let bonesLayer = CAShapeLayer()
    private let jointsLayer = CAShapeLayer()
    private var currentHand: HandSample?
    private var mapper: ((CGPoint) -> CGPoint?)?

    private let bones: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP)
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        bonesLayer.fillColor = UIColor.clear.cgColor
        bonesLayer.strokeColor = UIColor.white.withAlphaComponent(0.82).cgColor
        bonesLayer.lineWidth = 1.4
        bonesLayer.lineCap = .round
        layer.addSublayer(bonesLayer)

        jointsLayer.fillColor = UIColor.white.withAlphaComponent(0.92).cgColor
        jointsLayer.strokeColor = UIColor.clear.cgColor
        layer.addSublayer(jointsLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(hand: HandSample?, mapper: @escaping (CGPoint) -> CGPoint?) {
        currentHand = hand
        self.mapper = mapper
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        bonesLayer.frame = bounds
        jointsLayer.frame = bounds
        bonesLayer.path = nil
        jointsLayer.path = nil
        guard let hand = currentHand, let mapper else { return }

        var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        for (name, normalized) in hand.joints {
            if let mapped = mapper(normalized) {
                points[name] = mapped
            }
        }

        let bonePath = UIBezierPath()
        for (a, b) in bones {
            guard let pa = points[a], let pb = points[b] else { continue }
            bonePath.move(to: pa)
            bonePath.addLine(to: pb)
        }
        bonesLayer.path = bonePath.cgPath

        let jointPath = UIBezierPath()
        let radius: CGFloat = 2.8
        for point in points.values {
            jointPath.append(UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)))
        }
        jointsLayer.path = jointPath.cgPath
    }
}

final class StereoLensMaskView: UIView {
    var leftRect: CGRect = .zero { didSet { setNeedsLayout() } }
    var rightRect: CGRect = .zero { didSet { setNeedsLayout() } }

    private let maskLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        maskLayer.fillColor = UIColor.black.cgColor
        maskLayer.fillRule = .evenOdd
        layer.addSublayer(maskLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        maskLayer.frame = bounds
        let path = UIBezierPath(rect: bounds)
        let corner: CGFloat = 18
        path.append(UIBezierPath(roundedRect: leftRect, cornerRadius: corner))
        path.append(UIBezierPath(roundedRect: rightRect, cornerRadius: corner))
        maskLayer.path = path.cgPath
    }
}

final class MainMenuView: UIView {
    var onEnter: (() -> Void)?
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let enterButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        titleLabel.text = "HandAR Vision"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 34, weight: .medium)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        subtitleLabel.text = "VR / AR browser"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textAlignment = .center
        addSubview(subtitleLabel)

        var config = UIButton.Configuration.filled()
        config.title = "ВОЙТИ В AR"
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.16, alpha: 1)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 34)
        enterButton.configuration = config
        enterButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        enterButton.addAction(UIAction { [weak self] _ in self?.onEnter?() }, for: .touchUpInside)
        addSubview(enterButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = CGRect(x: 24, y: bounds.midY - 100, width: bounds.width - 48, height: 48)
        subtitleLabel.frame = CGRect(x: 24, y: bounds.midY - 55, width: bounds.width - 48, height: 22)
        enterButton.frame = CGRect(x: bounds.midX - 120, y: bounds.midY + 8, width: 240, height: 54)
    }
}
