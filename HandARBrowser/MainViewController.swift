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
}

final class MainViewController: UIViewController {
    private let tracking = ARStereoTrackingManager()
    private let hands = HandTracker()
    private let input = WebInputBridge()

    // One logical browser surface, rendered independently by two stereo eye views.
    private let browser: WKWebView = {
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.alwaysBounceVertical = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        return webView
    }()
    private var browserTimer: Timer?
    private var snapshotInProgress = false

    private let arSceneView = ARSCNView(frame: .zero)
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

    private let menu = MainMenuView()

    private var inAR = false
    private var browserAnchor: ARAnchor?
    private var browserWorldTransform: simd_float4x4?
    private var lastCenterGestureTime: CFTimeInterval = 0
    private var didCreateInitialAnchor = false

    // Physical-looking spatial browser: smaller than the previous versions.
    private let browserWorldWidth: Float = 0.82
    private let browserWorldHeight: Float = 0.47
    private let browserWorldDistance: Float = 1.55
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
        configureBrowser()
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
            self?.tracking.setInterfaceOrientation(self?.currentInterfaceOrientation() ?? .landscapeRight)
        }) { [weak self] _ in
            guard let self else { return }
            self.tracking.setInterfaceOrientation(self.currentInterfaceOrientation())
            self.updateEyeCameras()
        }
    }

    deinit {
        browserTimer?.invalidate()
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }

    private func buildInterface() {
        view.backgroundColor = .black

        // Full-screen AR camera background. The stereo views are transparent overlays.
        arSceneView.frame = view.bounds
        arSceneView.session = tracking.session
        arSceneView.scene = SCNScene()
        arSceneView.backgroundColor = .black
        arSceneView.isOpaque = true
        arSceneView.clipsToBounds = true
        arSceneView.contentMode = .scaleAspectFill
        arSceneView.autoenablesDefaultLighting = false
        arSceneView.rendersCameraGrain = false
        arSceneView.rendersMotionBlur = false
        arSceneView.isUserInteractionEnabled = false
        view.addSubview(browser)
        view.addSubview(arSceneView)

        leftEyeView.isOpaque = false
        leftEyeView.backgroundColor = .clear
        leftEyeView.scene = leftScene
        leftEyeView.pointOfView = leftCameraNode
        leftEyeView.autoenablesDefaultLighting = false
        leftEyeView.allowsCameraControl = false
        leftEyeView.isUserInteractionEnabled = false
        leftEyeView.rendersContinuously = true
        leftEyeView.isPlaying = true
        view.addSubview(leftEyeView)

        rightEyeView.isOpaque = false
        rightEyeView.backgroundColor = .clear
        rightEyeView.scene = rightScene
        rightEyeView.pointOfView = rightCameraNode
        rightEyeView.autoenablesDefaultLighting = false
        rightEyeView.allowsCameraControl = false
        rightEyeView.isUserInteractionEnabled = false
        rightEyeView.rendersContinuously = true
        rightEyeView.isPlaying = true
        view.addSubview(rightEyeView)

        menu.onEnter = { [weak self] in
            self?.requestCameraAndEnterAR()
        }
        view.addSubview(menu)

        setARVisible(false)
    }

    private func layoutViews() {
        let bounds = view.bounds
        arSceneView.frame = bounds

        let halfWidth = max(bounds.width * 0.5, 1)
        leftEyeView.frame = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        rightEyeView.frame = CGRect(
            x: halfWidth,
            y: 0,
            width: max(bounds.width - halfWidth, 1),
            height: bounds.height
        )

        // The hidden browser is rendered behind the AR camera so its snapshots remain live.
        let browserSize = CGSize(
            width: max(bounds.width - 80, 480),
            height: max(bounds.height - 80, 320)
        )
        browser.frame = CGRect(
            x: (bounds.width - browserSize.width) * 0.5,
            y: (bounds.height - browserSize.height) * 0.5,
            width: browserSize.width,
            height: browserSize.height
        )

        menu.frame = bounds
    }

    private func configureBrowser() {
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.load(URLRequest(url: Self.homeURL))
    }

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
        geometry.widthSegmentCount = 1
        geometry.heightSegmentCount = 1

        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.black
        material.emission.contents = UIColor.black
        material.specular.contents = UIColor.black
        material.shininess = 0

        planeNode.geometry = geometry
        scene.rootNode.addChildNode(planeNode)

        let cursorGeometry = SCNSphere(radius: 0.011)
        cursorGeometry.segmentCount = 12
        let cursorMaterial = SCNMaterial()
        cursorMaterial.lightingModel = .constant
        cursorMaterial.isDoubleSided = true
        cursorMaterial.diffuse.contents = UIColor.white
        cursorMaterial.emission.contents = UIColor.white
        cursorGeometry.firstMaterial = cursorMaterial
        cursorNode.geometry = cursorGeometry
        cursorNode.isHidden = true
        scene.rootNode.addChildNode(cursorNode)
    }

    private func wireServices() {
        browser.navigationDelegate = self
        browser.uiDelegate = self

        tracking.onFrame = { [weak self] pixelBuffer, orientation in
            self?.hands.process(pixelBuffer: pixelBuffer, orientation: orientation)
        }

        tracking.onCamera = { [weak self] frame in
            DispatchQueue.main.async {
                self?.updateEyeCameras(using: frame)
                self?.ensureBrowserAnchor(using: frame.camera.transform)
            }
        }

        tracking.onAnchorUpdate = { [weak self] anchor in
            DispatchQueue.main.async {
                guard let self, self.inAR else { return }
                guard self.browserAnchor?.identifier == anchor.identifier else { return }
                self.browserAnchor = anchor
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

        browserTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            self?.updateBrowserSnapshot()
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
        browser.isHidden = false
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
        guard view.bounds.width > view.bounds.height, view.bounds.width > 100 else { return }

        let position = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let forward = simd_normalize(SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        ))

        var transform = cameraTransform
        transform.columns.3 = SIMD4<Float>(position + forward * browserWorldDistance, 1)

        let anchor = ARAnchor(
            name: "HandAR_Stereo_Browser",
            transform: transform
        )

        browserAnchor = anchor
        browserWorldTransform = transform
        didCreateInitialAnchor = true
        tracking.add(anchor: anchor)
        applyBrowserWorldTransform()
    }

    private func applyBrowserWorldTransform() {
        guard let transform = browserWorldTransform else { return }
        leftPlaneNode.simdWorldTransform = transform
        rightPlaneNode.simdWorldTransform = transform
    }

    private func updateEyeCameras(using frame: ARFrame? = nil) {
        guard let frame = frame ?? tracking.latestFrameCopy else { return }
        guard view.bounds.width > 100, view.bounds.height > 100 else { return }

        let orientation = currentInterfaceOrientation()
        let fullWidth = view.bounds.width
        let halfWidth = max(fullWidth * 0.5, 1)
        let eyeSize = CGSize(width: halfWidth, height: view.bounds.height)

        var leftTransform = frame.camera.transform
        var rightTransform = frame.camera.transform

        let rightAxis = simd_normalize(SIMD3<Float>(
            frame.camera.transform.columns.0.x,
            frame.camera.transform.columns.0.y,
            frame.camera.transform.columns.0.z
        ))
        let center = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )

        leftTransform.columns.3 = SIMD4<Float>(center - rightAxis * (eyeSeparation * 0.5), 1)
        rightTransform.columns.3 = SIMD4<Float>(center + rightAxis * (eyeSeparation * 0.5), 1)

        leftCameraNode.simdWorldTransform = leftTransform
        rightCameraNode.simdWorldTransform = rightTransform

        let leftProjection = frame.camera.projectionMatrix(
            for: orientation,
            viewportSize: eyeSize,
            zNear: 0.01,
            zFar: 100
        )
        let rightProjection = frame.camera.projectionMatrix(
            for: orientation,
            viewportSize: eyeSize,
            zNear: 0.01,
            zFar: 100
        )

        leftCameraNode.camera?.projectionTransform = SCNMatrix4FromMat4(leftProjection)
        rightCameraNode.camera?.projectionTransform = SCNMatrix4FromMat4(rightProjection)
    }

    private func updateBrowserSnapshot() {
        guard inAR, !snapshotInProgress else { return }
        snapshotInProgress = true

        let configuration = WKSnapshotConfiguration()
        browser.takeSnapshot(with: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshotInProgress = false
                guard let image else { return }

                self.leftMaterial.diffuse.contents = image
                self.leftMaterial.emission.contents = image
                self.rightMaterial.diffuse.contents = image
                self.rightMaterial.emission.contents = image
            }
        }
    }

    private func handleHands(left: HandSample?, right: HandSample?) {
        guard inAR else { return }

        if left?.isPinching == true && right?.isPinching == true {
            let now = CACurrentMediaTime()
            if now - lastCenterGestureTime > 1.0 {
                lastCenterGestureTime = now
                resetBrowserAnchor()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            releasePointer()
            hideCursor()
            return
        }

        guard let sample = right ?? left else {
            releasePointer()
            hideCursor()
            return
        }

        guard let fullPoint = tracking.screenPoint(
            forVisionPoint: CGPoint(x: sample.indexTip.x, y: 1 - sample.indexTip.y),
            viewportSize: view.bounds.size
        ) else {
            releasePointer()
            hideCursor()
            return
        }

        guard let worldPoint = tracking.worldPointOnBrowser(
            screenPoint: fullPoint,
            viewportSize: view.bounds.size,
            planeTransform: browserPlaneForUnprojection()
        ) else {
            releasePointer()
            hideCursor()
            return
        }

        guard let transform = browserWorldTransform else {
            releasePointer()
            hideCursor()
            return
        }

        let center = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let rightAxis = simd_normalize(SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        ))
        let upAxis = simd_normalize(SIMD3<Float>(
            transform.columns.1.x,
            transform.columns.1.y,
            transform.columns.1.z
        ))

        let delta = worldPoint - center
        let localX = simd_dot(delta, rightAxis)
        let localY = simd_dot(delta, upAxis)
        let normalizedX = localX / browserWorldWidth + 0.5
        let normalizedY = 0.5 - localY / browserWorldHeight

        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else {
            releasePointer()
            hideCursor()
            return
        }

        leftCursorNode.simdPosition = worldPoint
        rightCursorNode.simdPosition = worldPoint
        leftCursorNode.isHidden = false
        rightCursorNode.isHidden = false

        input.update(
            normalizedPoint: CGPoint(x: normalizedX, y: normalizedY),
            pinch: sample.isPinching,
            webView: browser
        )
    }

    private func browserPlaneForUnprojection() -> simd_float4x4? {
        guard let transform = browserWorldTransform else { return nil }

        let right = SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        )
        let up = SIMD3<Float>(
            transform.columns.1.x,
            transform.columns.1.y,
            transform.columns.1.z
        )
        let normal = SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        )
        let center = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )

        // ARCamera.unprojectPoint uses the local XZ plane, whose local Y is its normal.
        var result = matrix_identity_float4x4
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

    private func hideCursor() {
        leftCursorNode.isHidden = true
        rightCursorNode.isHidden = true
    }

    private func releasePointer() {
        input.release(webView: browser)
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
        updateBrowserSnapshot()
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
        session.run(
            configuration,
            options: [.resetTracking, .removeExistingAnchors]
        )
    }

    func pause() {
        session.pause()
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
    }

    func add(anchor: ARAnchor) {
        session.add(anchor: anchor)
    }

    func remove(anchor: ARAnchor) {
        session.remove(anchor: anchor)
    }

    func screenPoint(
        forVisionPoint point: CGPoint,
        viewportSize: CGSize
    ) -> CGPoint? {
        guard let frame = latestFrameCopy else { return nil }
        let mapped = point.applying(
            frame.displayTransform(
                for: interfaceOrientation,
                viewportSize: viewportSize
            )
        )
        let result = CGPoint(
            x: mapped.x * viewportSize.width,
            y: mapped.y * viewportSize.height
        )
        guard result.x.isFinite, result.y.isFinite else { return nil }
        return result
    }

    func worldPointOnBrowser(
        screenPoint: CGPoint,
        viewportSize: CGSize,
        planeTransform: simd_float4x4?
    ) -> SIMD3<Float>? {
        guard let frame = latestFrameCopy, let planeTransform else { return nil }
        let halfWidth = viewportSize.width * 0.5
        guard halfWidth > 1 else { return nil }

        let localPoint: CGPoint
        let eyeViewport: CGSize
        if screenPoint.x < halfWidth {
            localPoint = CGPoint(x: screenPoint.x, y: screenPoint.y)
            eyeViewport = CGSize(width: halfWidth, height: viewportSize.height)
        } else {
            localPoint = CGPoint(x: screenPoint.x - halfWidth, y: screenPoint.y)
            eyeViewport = CGSize(width: halfWidth, height: viewportSize.height)
        }

        return frame.camera.unprojectPoint(
            localPoint,
            ontoPlane: planeTransform,
            orientation: interfaceOrientation,
            viewportSize: eyeViewport
        )
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameLock.lock()
        latestFrame = frame
        frameLock.unlock()

        let orientation = imageOrientation(for: interfaceOrientation)
        onFrame?(frame.capturedImage, orientation)
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
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .down
        case .landscapeRight:
            return .up
        default:
            return .up
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

    func process(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        guard gate.wait(timeout: .now()) == .success else { return }

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.gate.signal() }

            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation,
                options: [:]
            )

            do {
                try handler.perform([self.request])

                var left: HandSample?
                var right: HandSample?
                var foundLeft = false
                var foundRight = false

                for observation in self.request.results ?? [] {
                    guard
                        let index = try? observation.recognizedPoint(.indexTip),
                        let thumb = try? observation.recognizedPoint(.thumbTip),
                        let wrist = try? observation.recognizedPoint(.wrist),
                        let middle = try? observation.recognizedPoint(.middleMCP),
                        index.confidence > 0.68,
                        thumb.confidence > 0.62,
                        wrist.confidence > 0.48,
                        middle.confidence > 0.48
                    else {
                        continue
                    }

                    let isLeft = observation.chirality == .left
                    let oldIndex = isLeft ? self.lastIndexLeft : self.lastIndexRight
                    let oldThumb = isLeft ? self.lastThumbLeft : self.lastThumbRight

                    let indexAlpha = adaptiveAlpha(previous: oldIndex, current: index.location)
                    let thumbAlpha = adaptiveAlpha(previous: oldThumb, current: thumb.location)

                    let filteredIndex = smooth(oldIndex, index.location, alpha: indexAlpha)
                    let filteredThumb = smooth(oldThumb, thumb.location, alpha: thumbAlpha)

                    let palmSize = max(distance(wrist.location, middle.location), 0.03)
                    let ratio = distance(filteredIndex, filteredThumb) / palmSize
                    let wasPinching = isLeft ? self.pinchLeft : self.pinchRight
                    let pinching = pinchHysteresis(previous: wasPinching, ratio: ratio)

                    if isLeft {
                        self.lastIndexLeft = filteredIndex
                        self.lastThumbLeft = filteredThumb
                        self.pinchLeft = pinching
                        foundLeft = true
                        left = HandSample(indexTip: filteredIndex, thumbTip: filteredThumb, isPinching: pinching)
                    } else {
                        self.lastIndexRight = filteredIndex
                        self.lastThumbRight = filteredThumb
                        self.pinchRight = pinching
                        foundRight = true
                        right = HandSample(indexTip: filteredIndex, thumbTip: filteredThumb, isPinching: pinching)
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
    return CGPoint(
        x: old.x + (new.x - old.x) * alpha,
        y: old.y + (new.y - old.y) * alpha
    )
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

    func update(normalizedPoint: CGPoint, pinch: Bool, webView: WKWebView) {
        let x = normalizedPoint.x * webView.bounds.width
        let y = normalizedPoint.y * webView.bounds.height
        let current = CGPoint(x: x, y: y)
        let previous = lastPoint ?? current
        let deltaY = current.y - previous.y

        if pinch && !pointerDown {
            pointerDown = true
            dispatch("window.__handarPointerDown(\(x),\(y),1);", to: webView)
        } else if pinch && pointerDown {
            if abs(deltaY) > 0.75 {
                let amount = String(
                    format: "%.2f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    deltaY * 2.6
                )
                dispatch("window.scrollBy(0,\(amount));", to: webView)
            }
            dispatch("window.__handarPointerMove(\(x),\(y),1);", to: webView)
        } else if !pinch && pointerDown {
            pointerDown = false
            dispatch("window.__handarPointerUp(\(x),\(y),1);", to: webView)
        } else {
            dispatch("window.__handarHover(\(x),\(y));", to: webView)
        }

        lastPoint = current
    }

    func release(webView: WKWebView) {
        guard pointerDown else {
            lastPoint = nil
            return
        }
        pointerDown = false
        dispatch("window.__handarPointerUp(window.innerWidth/2,window.innerHeight/2,1);", to: webView)
        lastPoint = nil
    }

    private func dispatch(_ script: String, to webView: WKWebView) {
        webView.evaluateJavaScript(script, completionHandler: nil)
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

        subtitleLabel.text = "AR browser"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = CGRect(x: 24, y: bounds.midY - 100, width: bounds.width - 48, height: 48)
        subtitleLabel.frame = CGRect(x: 24, y: bounds.midY - 55, width: bounds.width - 48, height: 22)
        enterButton.frame = CGRect(x: bounds.midX - 120, y: bounds.midY + 8, width: 240, height: 54)
    }
}
