import UIKit
import AVFoundation
import ARKit
import RealityKit
import Vision
import WebKit

struct HandSample {
    let indexTip: CGPoint
    let thumbTip: CGPoint
    let isPinching: Bool
}

final class MainViewController: UIViewController {
    private let tracking = ARTrackingManager()
    private let hands = HandTracker()
    private let input = WebInputBridge()

    private var arView: ARView!
    private let eyeLeft = EyeDisplayView()
    private let eyeRight = EyeDisplayView()
    private let cursorLeft = CursorView()
    private let cursorRight = CursorView()
    private let menu = MainMenuView()

    private var inAR = false
    private var browserAnchor: ARAnchor?
    private var browserAnchorEntity: AnchorEntity?
    private var lastCenterGestureTime: CFTimeInterval = 0
    private var didRequestInitialAnchor = false

    // Smaller world-locked browser window, positioned comfortably in front of the user.
    private let browserWorldWidth: Float = 0.92
    private let browserWorldHeight: Float = 0.52
    private let browserWorldDistance: Float = 1.45

    // Each eye has its own independent WebView and a tiny binocular offset.
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
        buildInterface()
        wireServices()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        arView.frame = view.bounds
        menu.frame = view.bounds

        let halfWidth = max(view.bounds.width * 0.5, 1)
        eyeLeft.frame = CGRect(
            x: 0,
            y: 0,
            width: halfWidth,
            height: view.bounds.height
        )
        eyeRight.frame = CGRect(
            x: halfWidth,
            y: 0,
            width: max(view.bounds.width - halfWidth, 1),
            height: view.bounds.height
        )

        cursorLeft.bounds.size = CGSize(width: 20, height: 20)
        cursorRight.bounds.size = CGSize(width: 20, height: 20)

        guard !view.bounds.isEmpty else { return }
        tracking.setInterfaceOrientation(currentInterfaceOrientation())
        reprojectBrowser()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: { _ in
            self.tracking.setInterfaceOrientation(self.currentInterfaceOrientation())
        }) { _ in
            self.tracking.setInterfaceOrientation(self.currentInterfaceOrientation())
            self.reprojectBrowser()
        }
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }

    private func buildInterface() {
        view.backgroundColor = .black

        // ARView is the real AR passthrough/world-tracking layer.
        arView = ARView(
            frame: view.bounds,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        arView.backgroundColor = .black
        arView.isHidden = true
        arView.isUserInteractionEnabled = false
        arView.renderOptions.insert(.disableMotionBlur)
        arView.session = tracking.session
        view.addSubview(arView)

        // Important: these are two independent display surfaces, not one WebView split in half.
        eyeLeft.isHidden = true
        eyeRight.isHidden = true
        view.addSubview(eyeLeft)
        view.addSubview(eyeRight)

        cursorLeft.isHidden = true
        cursorRight.isHidden = true
        eyeLeft.addSubview(cursorLeft)
        eyeRight.addSubview(cursorRight)

        menu.onEnter = { [weak self] in
            self?.requestCameraAndEnterAR()
        }
        view.addSubview(menu)
    }

    private func wireServices() {
        eyeLeft.webView.navigationDelegate = self
        eyeRight.webView.navigationDelegate = self
        eyeLeft.webView.uiDelegate = self
        eyeRight.webView.uiDelegate = self
        input.mirror = [eyeLeft.webView, eyeRight.webView]

        tracking.onFrame = { [weak self] pixelBuffer, orientation in
            self?.hands.process(pixelBuffer: pixelBuffer, orientation: orientation)
        }

        tracking.onPose = { [weak self] cameraTransform in
            DispatchQueue.main.async {
                self?.ensureBrowserAnchor(using: cameraTransform)
            }
        }

        tracking.onAnchorUpdate = { [weak self] anchor in
            DispatchQueue.main.async {
                guard let self, self.inAR else { return }
                guard self.browserAnchor?.identifier == anchor.identifier else { return }
                self.browserAnchor = anchor
                self.reprojectBrowser()
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
                    allowed ? self.enterAR() : self.showAlert("Нужен доступ к задней камере для AR.")
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
        didRequestInitialAnchor = false
        lastCenterGestureTime = 0

        setNeedsUpdateOfSupportedInterfaceOrientations()
        requestLandscapeMode()

        eyeLeft.isHidden = false
        eyeRight.isHidden = false
        arView.isHidden = false
        menu.isHidden = true
        menu.isUserInteractionEnabled = false
        cursorLeft.isHidden = true
        cursorRight.isHidden = true

        eyeLeft.load(url: Self.homeURL)
        eyeRight.load(url: Self.homeURL)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.inAR else { return }
            self.tracking.setInterfaceOrientation(self.currentInterfaceOrientation())
            self.tracking.start()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func leaveARToMenu() {
        tracking.pause()

        if let anchor = browserAnchor {
            tracking.remove(anchor: anchor)
        }
        browserAnchor = nil
        browserAnchorEntity?.removeFromParent()
        browserAnchorEntity = nil
        didRequestInitialAnchor = false
        inAR = false

        arView.isHidden = true
        eyeLeft.isHidden = true
        eyeRight.isHidden = true
        cursorLeft.isHidden = true
        cursorRight.isHidden = true

        menu.isHidden = false
        menu.isUserInteractionEnabled = true
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private func requestLandscapeMode() {
        guard let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: [.landscapeLeft, .landscapeRight]),
            errorHandler: nil
        )
    }

    private func ensureBrowserAnchor(using cameraTransform: simd_float4x4) {
        guard inAR, !didRequestInitialAnchor else { return }
        guard view.bounds.width > view.bounds.height else { return }

        didRequestInitialAnchor = true

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

        var anchorTransform = cameraTransform
        anchorTransform.columns.3 = SIMD4<Float>(
            cameraPosition + forward * browserWorldDistance,
            1
        )

        let anchor = ARAnchor(
            name: "HandAR_Browser_WorldAnchor",
            transform: anchorTransform
        )

        browserAnchor = anchor
        tracking.add(anchor: anchor)

        // RealityKit uses the same ARAnchor, so the spatial object has a real world-space anchor.
        let anchorEntity = AnchorEntity(anchor: anchor)
        browserAnchorEntity = anchorEntity
        arView.scene.addAnchor(anchorEntity)

        reprojectBrowser()
    }

    private func reprojectBrowser() {
        guard
            inAR,
            let anchor = browserAnchor,
            view.bounds.width > view.bounds.height,
            view.bounds.width > 2
        else { return }

        let transform = anchor.transform
        let center = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let right = simd_normalize(SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        ))
        let up = simd_normalize(SIMD3<Float>(
            transform.columns.1.x,
            transform.columns.1.y,
            transform.columns.1.z
        ))

        let halfW = browserWorldWidth * 0.5
        let halfH = browserWorldHeight * 0.5
        let tl = center - right * halfW + up * halfH
        let tr = center + right * halfW + up * halfH
        let bl = center - right * halfW - up * halfH
        let br = center + right * halfW - up * halfH

        let halfScreen = view.bounds.width * 0.5
        projectEye(
            eye: eyeLeft,
            points: (tl, tr, bl, br),
            eyeOffset: +eyeSeparation * 0.5,
            originX: 0
        )
        projectEye(
            eye: eyeRight,
            points: (tl, tr, bl, br),
            eyeOffset: -eyeSeparation * 0.5,
            originX: halfScreen
        )
    }

    private func projectEye(
        eye: EyeDisplayView,
        points: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        eyeOffset: Float,
        originX: CGFloat
    ) {
        let viewport = view.bounds.size
        guard viewport.width > 20, viewport.height > 20 else { return }

        guard
            let p0 = tracking.projectWorldPoint(points.0, viewportSize: viewport, eyeOffset: eyeOffset),
            let p1 = tracking.projectWorldPoint(points.1, viewportSize: viewport, eyeOffset: eyeOffset),
            let p2 = tracking.projectWorldPoint(points.2, viewportSize: viewport, eyeOffset: eyeOffset),
            let p3 = tracking.projectWorldPoint(points.3, viewportSize: viewport, eyeOffset: eyeOffset)
        else { return }

        eye.setProjectedQuad(
            topLeft: CGPoint(x: p0.x - originX, y: p0.y),
            topRight: CGPoint(x: p1.x - originX, y: p1.y),
            bottomLeft: CGPoint(x: p2.x - originX, y: p2.y),
            bottomRight: CGPoint(x: p3.x - originX, y: p3.y)
        )
    }

    private func handleHands(left: HandSample?, right: HandSample?) {
        guard inAR else { return }

        if left?.isPinching == true && right?.isPinching == true {
            let now = CACurrentMediaTime()
            if now - lastCenterGestureTime > 1.0 {
                lastCenterGestureTime = now
                if let anchor = browserAnchor {
                    tracking.remove(anchor: anchor)
                }
                browserAnchor = nil
                browserAnchorEntity?.removeFromParent()
                browserAnchorEntity = nil
                didRequestInitialAnchor = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            releasePointers()
            cursorLeft.isHidden = true
            cursorRight.isHidden = true
            return
        }

        guard let sample = right ?? left else {
            releasePointers()
            cursorLeft.isHidden = true
            cursorRight.isHidden = true
            return
        }

        guard let screenPoint = tracking.screenPoint(
            forVisionPoint: CGPoint(x: sample.indexTip.x, y: 1 - sample.indexTip.y),
            viewportSize: view.bounds.size
        ) else {
            releasePointers()
            cursorLeft.isHidden = true
            cursorRight.isHidden = true
            return
        }

        let activeEye = screenPoint.x < view.bounds.midX ? eyeLeft : eyeRight
        let localPoint = activeEye.convert(screenPoint, from: view)

        guard let normalized = activeEye.normalizedPoint(fromEyePoint: localPoint) else {
            releasePointers()
            cursorLeft.isHidden = true
            cursorRight.isHidden = true
            return
        }

        cursorLeft.isHidden = false
        cursorRight.isHidden = false
        cursorLeft.center = eyeLeft.eyePoint(fromNormalized: normalized)
        cursorRight.center = eyeRight.eyePoint(fromNormalized: normalized)
        cursorLeft.setPressed(sample.isPinching)
        cursorRight.setPressed(sample.isPinching)

        input.updateBoth(
            normalizedPoint: normalized,
            pinch: sample.isPinching,
            left: eyeLeft.webView,
            right: eyeRight.webView
        )
    }

    private func releasePointers() {
        input.release(pointerID: 1, webView: eyeLeft.webView)
        input.release(pointerID: 2, webView: eyeRight.webView)
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
        guard let url = webView.url else { return }
        let other = webView === eyeLeft.webView ? eyeRight.webView : eyeLeft.webView
        if other.url?.absoluteString != url.absoluteString {
            other.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
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

final class ARTrackingManager: NSObject, ARSessionDelegate {
    let session = ARSession()

    private var latestFrame: ARFrame?
    private let frameLock = NSLock()
    private var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?
    var onPose: ((simd_float4x4) -> Void)?
    var onAnchorUpdate: ((ARAnchor) -> Void)?
    var onFailure: ((String) -> Void)?

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

    func add(anchor: ARAnchor) { session.add(anchor: anchor) }
    func remove(anchor: ARAnchor) { session.remove(anchor: anchor) }

    func projectWorldPoint(
        _ worldPoint: SIMD3<Float>,
        viewportSize: CGSize,
        eyeOffset: Float
    ) -> CGPoint? {
        frameLock.lock()
        let frame = latestFrame
        let orientation = interfaceOrientation
        frameLock.unlock()

        guard let frame else { return nil }

        let cameraTransform = frame.camera.transform
        let cameraRight = simd_normalize(SIMD3<Float>(
            cameraTransform.columns.0.x,
            cameraTransform.columns.0.y,
            cameraTransform.columns.0.z
        ))
        let adjusted = worldPoint + cameraRight * eyeOffset

        let projected = frame.camera.projectPoint(
            adjusted,
            orientation: orientation,
            viewportSize: viewportSize
        )

        guard projected.x.isFinite, projected.y.isFinite else { return nil }
        return projected
    }

    func screenPoint(
        forVisionPoint point: CGPoint,
        viewportSize: CGSize
    ) -> CGPoint? {
        frameLock.lock()
        let frame = latestFrame
        let orientation = interfaceOrientation
        frameLock.unlock()
        guard let frame else { return nil }

        let mapped = point.applying(
            frame.displayTransform(
                for: orientation,
                viewportSize: viewportSize
            )
        )

        return CGPoint(
            x: mapped.x * viewportSize.width,
            y: mapped.y * viewportSize.height
        )
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameLock.lock()
        latestFrame = frame
        frameLock.unlock()

        let orientation = imageOrientation(for: interfaceOrientation)
        onFrame?(frame.capturedImage, orientation)
        onPose?(frame.camera.transform)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors {
            onAnchorUpdate?(anchor)
        }
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
        default: return .right
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

    private let queue = DispatchQueue(
        label: "handar.vision",
        qos: .userInitiated
    )

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
                        let middleMCP = try? observation.recognizedPoint(.middleMCP),
                        index.confidence > 0.62,
                        thumb.confidence > 0.58,
                        wrist.confidence > 0.45,
                        middleMCP.confidence > 0.45
                    else {
                        continue
                    }

                    let isLeft = observation.chirality == .left

                    let previousIndex = isLeft
                        ? self.lastIndexLeft
                        : self.lastIndexRight

                    let previousThumb = isLeft
                        ? self.lastThumbLeft
                        : self.lastThumbRight

                    let indexAlpha = adaptiveAlpha(
                        previous: previousIndex,
                        current: index.location
                    )

                    let thumbAlpha = adaptiveAlpha(
                        previous: previousThumb,
                        current: thumb.location
                    )

                    let filteredIndex = smooth(
                        previousIndex,
                        index.location,
                        alpha: indexAlpha
                    )

                    let filteredThumb = smooth(
                        previousThumb,
                        thumb.location,
                        alpha: thumbAlpha
                    )

                    if isLeft {
                        self.lastIndexLeft = filteredIndex
                        self.lastThumbLeft = filteredThumb
                        foundLeft = true
                    } else {
                        self.lastIndexRight = filteredIndex
                        self.lastThumbRight = filteredThumb
                        foundRight = true
                    }

                    let palmSize = max(
                        distance(wrist.location, middleMCP.location),
                        0.03
                    )

                    let pinchRatio = distance(
                        filteredIndex,
                        filteredThumb
                    ) / palmSize

                    let wasPinching = isLeft
                        ? self.pinchLeft
                        : self.pinchRight

                    let pinching = pinchHysteresis(
                        previous: wasPinching,
                        ratio: pinchRatio
                    )

                    if isLeft {
                        self.pinchLeft = pinching
                    } else {
                        self.pinchRight = pinching
                    }

                    let sample = HandSample(
                        indexTip: filteredIndex,
                        thumbTip: filteredThumb,
                        isPinching: pinching
                    )

                    if isLeft {
                        left = sample
                    } else {
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
private func smooth(
    _ old: CGPoint?,
    _ new: CGPoint,
    alpha: CGFloat
) -> CGPoint {
    guard let old else { return new }

    return CGPoint(
        x: old.x + (new.x - old.x) * alpha,
        y: old.y + (new.y - old.y) * alpha
    )
}

@inline(__always)
private func adaptiveAlpha(
    previous: CGPoint?,
    current: CGPoint
) -> CGFloat {
    guard let previous else { return 1.0 }

    let jump = min(distance(previous, current), 0.30)

    // Low movement -> stable cursor. Fast movement -> lower latency.
    return min(
        0.82,
        max(
            0.20,
            0.20 + jump * 2.0
        )
    )
}

@inline(__always)
private func pinchHysteresis(
    previous: Bool,
    ratio: CGFloat
) -> Bool {
    if previous {
        return ratio < 0.60
    }

    return ratio < 0.44
}

@inline(__always)
private func distance(
    _ a: CGPoint,
    _ b: CGPoint
) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}


final class WebInputBridge {
    private struct State {
        var last: CGPoint?
        var down = false
    }

    private var states: [Int: State] = [:]
    var mirror: [WKWebView] = []

    func updateBoth(
        normalizedPoint: CGPoint,
        pinch: Bool,
        left: WKWebView,
        right: WKWebView
    ) {
        update(pointerID: 1, point: normalizedPoint, pinch: pinch, webView: left)
        update(pointerID: 2, point: normalizedPoint, pinch: pinch, webView: right)
    }

    private func update(
        pointerID: Int,
        point: CGPoint,
        pinch: Bool,
        webView: WKWebView
    ) {
        var state = states[pointerID] ?? State()
        let current = CGPoint(
            x: point.x * webView.bounds.width,
            y: point.y * webView.bounds.height
        )
        let deltaY = current.y - (state.last?.y ?? current.y)

        if pinch && !state.down {
            state.down = true
            dispatch("window.__handarPointerDown(\(current.x),\(current.y),\(pointerID));", to: webView)
        } else if pinch && state.down {
            if abs(deltaY) > 0.75 {
                let amount = String(
                    format: "%.2f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    deltaY * 2.4
                )
                dispatch("window.scrollBy(0,\(amount));", to: webView)
            }
            dispatch("window.__handarPointerMove(\(current.x),\(current.y),\(pointerID));", to: webView)
        } else if !pinch && state.down {
            state.down = false
            dispatch("window.__handarPointerUp(\(current.x),\(current.y),\(pointerID));", to: webView)
        } else {
            dispatch("window.__handarHover(\(current.x),\(current.y));", to: webView)
        }

        state.last = current
        states[pointerID] = state
    }

    func release(pointerID: Int, webView: WKWebView) {
        guard var state = states[pointerID] else { return }
        if state.down {
            state.down = false
            dispatch(
                "window.__handarPointerUp(window.innerWidth/2,window.innerHeight/2,\(pointerID));",
                to: webView
            )
        }
        state.last = nil
        states[pointerID] = state
    }

    private func dispatch(_ script: String, to webView: WKWebView) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

final class EyeDisplayView: UIView {
    let webView: WKWebView

    private let screen = UIView()
    private let glass = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemUltraThinMaterialDark)
    )

    override init(frame: CGRect = .zero) {
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

        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)

        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = false

        // Each eye receives its own rectangular spatial display.
        screen.backgroundColor = UIColor(white: 0.02, alpha: 0.10)
        screen.layer.cornerRadius = 18
        screen.layer.cornerCurve = .continuous
        screen.layer.borderWidth = 0.8
        screen.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        screen.layer.shadowColor = UIColor.black.cgColor
        screen.layer.shadowOpacity = 0.48
        screen.layer.shadowRadius = 22
        screen.layer.shadowOffset = CGSize(width: 0, height: 10)
        addSubview(screen)

        glass.isUserInteractionEnabled = false
        glass.alpha = 0.10
        glass.clipsToBounds = true
        glass.layer.cornerRadius = 18
        glass.layer.cornerCurve = .continuous
        screen.addSubview(glass)

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.alwaysBounceVertical = true
        webView.layer.cornerRadius = 17
        webView.layer.cornerCurve = .continuous
        webView.clipsToBounds = true
        screen.addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = bounds.width * 0.92
        let height = bounds.height * 0.70
        let frame = CGRect(
            x: (bounds.width - width) * 0.5,
            y: (bounds.height - height) * 0.5,
            width: width,
            height: height
        )

        screen.bounds = CGRect(origin: .zero, size: frame.size)
        screen.center = frame.midPoint
        screen.transform = .identity
        glass.frame = screen.bounds
        webView.frame = screen.bounds.insetBy(dx: 1, dy: 1)
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    func setProjectedQuad(
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint
    ) {
        let baseWidth = max(screen.bounds.width, 1)
        let baseHeight = max(screen.bounds.height, 1)

        let h = CGPoint(
            x: topRight.x - topLeft.x,
            y: topRight.y - topLeft.y
        )
        let v = CGPoint(
            x: bottomLeft.x - topLeft.x,
            y: bottomLeft.y - topLeft.y
        )

        let a = h.x / baseWidth
        let b = h.y / baseWidth
        let c = v.x / baseHeight
        let d = v.y / baseHeight

        let center = CGPoint(
            x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) * 0.25,
            y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) * 0.25
        )

        guard center.x.isFinite, center.y.isFinite,
              a.isFinite, b.isFinite, c.isFinite, d.isFinite else { return }

        screen.center = center
        screen.transform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: 0, ty: 0)
    }

    func normalizedPoint(fromEyePoint point: CGPoint) -> CGPoint? {
        let local = screen.convert(point, from: self)
        guard screen.bounds.contains(local) else { return nil }
        return CGPoint(
            x: min(max(local.x / max(screen.bounds.width, 1), 0), 1),
            y: min(max(local.y / max(screen.bounds.height, 1), 0), 1)
        )
    }

    func eyePoint(fromNormalized point: CGPoint) -> CGPoint {
        let local = CGPoint(
            x: min(max(point.x, 0), 1) * screen.bounds.width,
            y: min(max(point.y, 0), 1) * screen.bounds.height
        )
        return screen.convert(local, to: self)
    }
}

final class CursorView: UIView {
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        layer.borderWidth = 1.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.92).cgColor
        layer.cornerRadius = 10

        dot.backgroundColor = .white
        dot.layer.cornerRadius = 2.5
        addSubview(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = CGRect(
            x: bounds.midX - 2.5,
            y: bounds.midY - 2.5,
            width: 5,
            height: 5
        )
    }

    func setPressed(_ pressed: Bool) {
        alpha = pressed ? 1 : 0.82
        transform = pressed
            ? CGAffineTransform(scaleX: 1.15, y: 1.15)
            : .identity
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
        titleLabel.font = .systemFont(
            ofSize: 34,
            weight: .medium
        )
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        subtitleLabel.text = "Spatial browser"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        subtitleLabel.font = .systemFont(
            ofSize: 15,
            weight: .regular
        )
        subtitleLabel.textAlignment = .center
        addSubview(subtitleLabel)

        var config = UIButton.Configuration.filled()
        config.title = "ВОЙТИ В AR"
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(
            white: 0.16,
            alpha: 1
        )
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: 34,
            bottom: 0,
            trailing: 34
        )

        enterButton.configuration = config
        enterButton.titleLabel?.font = .systemFont(
            ofSize: 18,
            weight: .semibold
        )

        enterButton.layer.borderWidth = 1
        enterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor

        enterButton.addAction(
            UIAction { [weak self] _ in
                self?.onEnter?()
            },
            for: .touchUpInside
        )

        addSubview(enterButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        titleLabel.frame = CGRect(
            x: 24,
            y: bounds.midY - 110,
            width: bounds.width - 48,
            height: 48
        )

        subtitleLabel.frame = CGRect(
            x: 24,
            y: bounds.midY - 60,
            width: bounds.width - 48,
            height: 24
        )

        enterButton.frame = CGRect(
            x: bounds.midX - 145,
            y: bounds.midY - 15,
            width: 290,
            height: 58
        )
    }
}

private extension CGRect {
    var midPoint: CGPoint {
        CGPoint(
            x: midX,
            y: midY
        )
    }
}
