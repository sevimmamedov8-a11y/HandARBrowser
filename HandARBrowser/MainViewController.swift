import UIKit
import AVFoundation
import ARKit
import RealityKit
import Vision
import WebKit

struct ARPose {
    let transform: simd_float4x4
}

private struct WorldBrowserAnchor {
    let center: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
}

final class MainViewController: UIViewController {
    private let tracking = ARTrackingManager()
    private let hands = HandTracker()
    private let input = WebInputBridge()

    private var arView: ARView!
    private let eyeLeft = EyeContainer()
    private let eyeRight = EyeContainer()
    private let cursor = CursorView()
    private let lensMask = LensMaskView()
    private let menu = MainMenuView()

    private var lastSize: CGSize = .zero
    private var inAR = false
    private var worldBrowserAnchor: WorldBrowserAnchor?
    private var lastCenterGestureTime = CACurrentMediaTime()

    // Virtual browser plane in meters. Kept slightly smaller and anchored in AR world space.
    private let browserWorldWidth: Float = 0.76
    private let browserWorldHeight: Float = 0.48
    private let browserWorldDistance: Float = 1.35
    private let stereoGap: Float = 0.028

    override var prefersStatusBarHidden: Bool { true }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override var prefersHomeIndicatorAutoHidden: Bool { inAR }

    private static let homeURL = URL(string: "https://www.google.com/")!

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        wireServices()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize else {
            updateInterfaceOrientation()
            return
        }
        lastSize = view.bounds.size

        arView.frame = view.bounds
        menu.frame = view.bounds
        lensMask.frame = view.bounds

        let isLandscape = view.bounds.width >= view.bounds.height
        if isLandscape {
            let half = view.bounds.width / 2
            eyeLeft.frame = CGRect(x: 0, y: 0, width: half, height: view.bounds.height)
            eyeRight.frame = CGRect(x: half, y: 0, width: half, height: view.bounds.height)
        } else {
            let half = view.bounds.height / 2
            eyeLeft.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: half)
            eyeRight.frame = CGRect(x: 0, y: half, width: view.bounds.width, height: half)
        }

        cursor.bounds.size = CGSize(width: 20, height: 20)
        updateInterfaceOrientation()
        applyReferencePoseIfPossible()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.lastSize = .zero
            self?.view.setNeedsLayout()
            self?.view.layoutIfNeeded()
        })
    }

    private func buildInterface() {
        view.backgroundColor = .black

        arView = ARView(frame: view.bounds, cameraMode: .ar, automaticallyConfigureSession: false)
        arView.backgroundColor = .black
        arView.isHidden = true
        arView.isUserInteractionEnabled = false
        arView.renderOptions.insert(.disableMotionBlur)
        view.addSubview(arView)
        arView.session = tracking.session

        eyeLeft.alpha = 0.98
        eyeRight.alpha = 0.98
        eyeLeft.isHidden = true
        eyeRight.isHidden = true
        view.addSubview(eyeLeft)
        view.addSubview(eyeRight)

        cursor.isHidden = true
        view.addSubview(cursor)

        lensMask.isHidden = true
        view.addSubview(lensMask)

        menu.onEnter = { [weak self] in
            self?.requestARAccessAndEnter()
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
        tracking.onPose = { [weak self] pose in
            DispatchQueue.main.async {
                self?.applyARPose(pose)
            }
        }
        tracking.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.leaveARForMenu()
                self?.showAlert(message)
            }
        }

        hands.onUpdate = { [weak self] left, right in
            DispatchQueue.main.async {
                self?.handleHands(left: left, right: right)
            }
        }
    }

    private func requestARAccessAndEnter() {
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
                    if allowed {
                        self?.enterAR()
                    } else {
                        self?.showAlert("Нужен доступ к задней камере для режима AR.")
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
        worldBrowserAnchor = nil
        tracking.setInterfaceOrientation(currentInterfaceOrientation)
        arView.isHidden = false
        eyeLeft.isHidden = false
        eyeRight.isHidden = false
        lensMask.isHidden = false
        eyeLeft.load(url: Self.homeURL)
        eyeRight.load(url: Self.homeURL)

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        tracking.start()

        menu.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.28, animations: {
            self.menu.alpha = 0
            self.menu.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
        }, completion: { _ in
            self.menu.isHidden = true
        })
    }

    private func leaveARForMenu() {
        tracking.pause()
        arView.isHidden = true
        eyeLeft.isHidden = true
        eyeRight.isHidden = true
        lensMask.isHidden = true
        cursor.isHidden = true
        inAR = false
        worldBrowserAnchor = nil
        menu.isHidden = false
        menu.alpha = 0
        menu.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
        UIView.animate(withDuration: 0.2) {
            self.menu.alpha = 1
            self.menu.transform = .identity
        } completion: { _ in
            self.menu.isUserInteractionEnabled = true
        }
    }

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }

    private func updateInterfaceOrientation() {
        tracking.setInterfaceOrientation(currentInterfaceOrientation)
    }

    private func applyARPose(_ pose: ARPose) {
        guard inAR else { return }

        if worldBrowserAnchor == nil {
            let transform = pose.transform
            let cameraPosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let cameraRight = normalized(SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
            let cameraUp = normalized(SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
            let cameraForward = normalized(-SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
            worldBrowserAnchor = WorldBrowserAnchor(
                center: cameraPosition + cameraForward * browserWorldDistance,
                right: cameraRight,
                up: cameraUp
            )
        }

        guard worldBrowserAnchor != nil else { return }

        // The plane is fixed in AR/world space. ARKit projects the same 3D
        // rectangle into every new camera pose, so turning the phone does not
        // move the browser with the head. It stays at the original world spot.
        reprojectWorldBrowser()
    }

    private func projectEye(
        eye: EyeContainer,
        worldCenter: SIMD3<Float>,
        worldRight: SIMD3<Float>,
        worldUp: SIMD3<Float>,
        halfWidth: Float,
        halfHeight: Float
    ) {
        guard eye.browserFrame != .zero else { return }
        guard
            let center = tracking.projectWorldPoint(worldCenter, viewportSize: view.bounds.size),
            let left = tracking.projectWorldPoint(worldCenter - worldRight * halfWidth, viewportSize: view.bounds.size),
            let right = tracking.projectWorldPoint(worldCenter + worldRight * halfWidth, viewportSize: view.bounds.size),
            let top = tracking.projectWorldPoint(worldCenter + worldUp * halfHeight, viewportSize: view.bounds.size),
            let bottom = tracking.projectWorldPoint(worldCenter - worldUp * halfHeight, viewportSize: view.bounds.size)
        else { return }

        let projectedWidth = max(distance(left, right), 1)
        let projectedHeight = max(distance(top, bottom), 1)
        let scaleX = projectedWidth / max(eye.browserFrame.width, 1)
        let scaleY = projectedHeight / max(eye.browserFrame.height, 1)
        let scale = CGFloat(clamp(Double(min(scaleX, scaleY)), min: 0.55, max: 2.25))
        let rotation = atan2(right.y - left.y, right.x - left.x)
        eye.setWorldProjection(globalCenter: center, in: view, scale: scale, rotation: rotation)
    }

    private func applyReferencePoseIfPossible() {
        reprojectWorldBrowser()
    }

    private func reprojectWorldBrowser() {
        guard inAR, let anchor = worldBrowserAnchor else { return }
        let eyeWidth = (browserWorldWidth - stereoGap) * 0.5
        let halfHeight = browserWorldHeight * 0.5
        let halfEyeWidth = eyeWidth * 0.5

        let leftCenter = anchor.center - anchor.right * (stereoGap * 0.5 + halfEyeWidth)
        let rightCenter = anchor.center + anchor.right * (stereoGap * 0.5 + halfEyeWidth)

        projectEye(eye: eyeLeft, worldCenter: leftCenter, worldRight: anchor.right, worldUp: anchor.up, halfWidth: halfEyeWidth, halfHeight: halfHeight)
        projectEye(eye: eyeRight, worldCenter: rightCenter, worldRight: anchor.right, worldUp: anchor.up, halfWidth: halfEyeWidth, halfHeight: halfHeight)
    }

    private func handleHands(left: HandSample?, right: HandSample?) {
        guard inAR else { return }

        if left?.isPinching == true && right?.isPinching == true {
            let now = CACurrentMediaTime()
            if now - lastCenterGestureTime > 1.0 {
                lastCenterGestureTime = now
                worldBrowserAnchor = nil
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            releasePointers()
            cursor.isHidden = true
            return
        }

        let sample = right ?? left
        guard let sample else {
            cursor.isHidden = true
            releasePointers()
            return
        }

        let devicePoint = CGPoint(x: sample.indexTip.x, y: 1 - sample.indexTip.y)
        let point = pointOnScreen(fromCaptureDevicePoint: devicePoint)
        cursor.isHidden = false
        cursor.center = point
        cursor.setPressed(sample.isPinching)

        if let eye = eyeForScreenPoint(point) {
            let localPoint = eye.convert(point, from: view)
            sendPointer(localPoint: localPoint, eye: eye, pointerID: 1, pinch: sample.isPinching)
        } else {
            releasePointers()
        }
    }

    private func pointOnScreen(fromCaptureDevicePoint point: CGPoint) -> CGPoint {
        tracking.screenPoint(forVisionPoint: point, viewportSize: view.bounds.size)
            ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    private func eyeForScreenPoint(_ point: CGPoint) -> EyeContainer? {
        if view.bounds.width >= view.bounds.height {
            return point.x < view.bounds.midX ? eyeLeft : eyeRight
        } else {
            return point.y < view.bounds.midY ? eyeLeft : eyeRight
        }
    }

    private func sendPointer(localPoint: CGPoint, eye: EyeContainer, pointerID: Int, pinch: Bool) {
        guard let webPoint = eye.webPoint(fromEyePoint: localPoint) else {
            input.release(pointerID: pointerID, webView: eye.webView)
            return
        }
        input.update(pointerID: pointerID, point: webPoint, pinch: pinch, webView: eye.webView)
    }

    private func releasePointers() {
        input.release(pointerID: 1, webView: eyeLeft.webView)
        input.release(pointerID: 1, webView: eyeRight.webView)
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }

    private func showAlert(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "HandAR Vision", message: message, preferredStyle: .alert)
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

struct HandSample {
    let indexTip: CGPoint
    let thumbTip: CGPoint
    let isPinching: Bool
}

@inline(__always)
private func smooth(_ old: CGPoint?, _ new: CGPoint, alpha: CGFloat) -> CGPoint {
    guard let old else { return new }
    return CGPoint(x: old.x + (new.x - old.x) * alpha,
                   y: old.y + (new.y - old.y) * alpha)
}

final class ARTrackingManager: NSObject, ARSessionDelegate {
    let session = ARSession()
    private var latestFrame: ARFrame?
    private let frameLock = NSLock()
    private var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?
    var onPose: ((ARPose) -> Void)?
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
        configuration.isAutoFocusEnabled = true
        configuration.worldAlignment = .gravity
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

    func projectWorldPoint(_ worldPoint: SIMD3<Float>, viewportSize: CGSize) -> CGPoint? {
        frameLock.lock()
        let frame = latestFrame
        let orientation = interfaceOrientation
        frameLock.unlock()
        guard let frame else { return nil }
        let point = frame.camera.projectPoint(worldPoint, orientation: orientation, viewportSize: viewportSize)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    func screenPoint(forVisionPoint point: CGPoint, viewportSize: CGSize) -> CGPoint? {
        frameLock.lock()
        let frame = latestFrame
        let orientation = interfaceOrientation
        frameLock.unlock()
        guard let frame else { return nil }

        let normalized = CGPoint(x: point.x, y: 1 - point.y)
        let transform = frame.displayTransform(for: orientation, viewportSize: viewportSize)
        let p = normalized.applying(transform)
        return CGPoint(x: p.x * viewportSize.width, y: p.y * viewportSize.height)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameLock.lock()
        latestFrame = frame
        frameLock.unlock()
        let orientation = imageOrientation(for: interfaceOrientation)
        onFrame?(frame.capturedImage, orientation)

        onPose?(ARPose(transform: frame.camera.transform))
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
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
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
                    guard
                        let index = try? observation.recognizedPoint(.indexTip),
                        let thumb = try? observation.recognizedPoint(.thumbTip),
                        let wrist = try? observation.recognizedPoint(.wrist),
                        let middleMCP = try? observation.recognizedPoint(.middleMCP),
                        index.confidence > 0.55,
                        thumb.confidence > 0.50,
                        wrist.confidence > 0.35,
                        middleMCP.confidence > 0.35
                    else { continue }

                    let isLeft = observation.chirality == .left
                    let previousIndex = isLeft ? self.lastIndexLeft : self.lastIndexRight
                    let previousThumb = isLeft ? self.lastThumbLeft : self.lastThumbRight
                    let indexAlpha = adaptiveAlpha(previous: previousIndex, current: index.location)
                    let thumbAlpha = adaptiveAlpha(previous: previousThumb, current: thumb.location)
                    let filteredIndex = smooth(previousIndex, index.location, alpha: indexAlpha)
                    let filteredThumb = smooth(previousThumb, thumb.location, alpha: thumbAlpha)

                    if isLeft {
                        self.lastIndexLeft = filteredIndex
                        self.lastThumbLeft = filteredThumb
                        foundLeft = true
                    } else {
                        self.lastIndexRight = filteredIndex
                        self.lastThumbRight = filteredThumb
                        foundRight = true
                    }

                    let palmSize = max(distance(wrist.location, middleMCP.location), 0.03)
                    let pinchRatio = distance(filteredIndex, filteredThumb) / palmSize
                    let wasPinching = isLeft ? self.pinchLeft : self.pinchRight
                    let pinching = pinchHysteresis(previous: wasPinching, ratio: pinchRatio)
                    if isLeft { self.pinchLeft = pinching } else { self.pinchRight = pinching }

                    let sample = HandSample(indexTip: filteredIndex, thumbTip: filteredThumb, isPinching: pinching)
                    if isLeft { left = sample } else { right = sample }
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
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

@inline(__always)
private func adaptiveAlpha(previous: CGPoint?, current: CGPoint) -> CGFloat {
    guard let previous else { return 1.0 }
    let jump = min(distance(previous, current), 0.35)
    // Stable hand = stronger smoothing, fast hand movement = less lag.
    return min(0.72, max(0.26, 0.26 + jump * 1.55))
}

@inline(__always)
private func pinchHysteresis(previous: Bool, ratio: CGFloat) -> Bool {
    if previous { return ratio < 0.58 }
    return ratio < 0.43
}

final class WebInputBridge {
    private struct State {
        var last: CGPoint?
        var down = false
    }
    private var states: [Int: State] = [:]
    var mirror: [WKWebView] = []

    func update(pointerID: Int, point: CGPoint, pinch: Bool, webView: WKWebView) {
        var state = states[pointerID] ?? State()
        let deltaY = point.y - (state.last?.y ?? point.y)

        if pinch && !state.down {
            state.down = true
            dispatch("window.__handarPointerDown(\(point.x),\(point.y),\(pointerID));", to: webView)
        } else if pinch && state.down {
            if abs(deltaY) > 0.5 {
                let amount = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), deltaY * 2.6)
                dispatch("window.scrollBy(0, \(amount));", to: webView)
                mirror.filter { $0 !== webView }.forEach { dispatch("window.scrollBy(0, \(amount));", to: $0) }
            }
            dispatch("window.__handarPointerMove(\(point.x),\(point.y),\(pointerID));", to: webView)
        } else if !pinch && state.down {
            state.down = false
            dispatch("window.__handarPointerUp(\(point.x),\(point.y),\(pointerID));", to: webView)
        } else {
            dispatch("window.__handarHover(\(point.x),\(point.y));", to: webView)
        }
        state.last = point
        states[pointerID] = state
    }

    func release(pointerID: Int, webView: WKWebView) {
        guard var state = states[pointerID] else { return }
        if state.down {
            state.down = false
            dispatch("window.__handarPointerUp(window.innerWidth/2, window.innerHeight/2, \(pointerID));", to: webView)
        }
        state.last = nil
        states[pointerID] = state
    }

    private func dispatch(_ script: String, to webView: WKWebView) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}


private extension CGRect {
    var midPoint: CGPoint { CGPoint(x: midX, y: midY) }
}

final class EyeContainer: UIView {
    let webView: WKWebView
    private let panel = UIView()
    private var panelTransform: CGAffineTransform = .identity
    private(set) var browserFrame: CGRect = .zero

    init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        if let path = Bundle.main.path(forResource: "WebInput", ofType: "js"),
           let js = try? String(contentsOfFile: path, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)

        backgroundColor = .clear
        clipsToBounds = false

        panel.backgroundColor = UIColor.black.withAlphaComponent(0.16)
        panel.layer.cornerRadius = 22
        panel.layer.borderWidth = 1
        panel.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.25
        panel.layer.shadowRadius = 18
        panel.layer.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(panel)
        panel.addSubview(webView)

        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear
        webView.alpha = 0.96
        webView.scrollView.alwaysBounceVertical = true
        webView.allowsBackForwardNavigationGestures = true
        webView.layer.cornerRadius = 21
        webView.clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Base rectangle used only as the local canvas. ARKit projects this same
        // virtual rectangle into the camera view and then offsets the panel.
        let panelW = bounds.width * 0.72
        let panelH = bounds.height * 0.50
        let panelFrame = CGRect(
            x: (bounds.width - panelW) / 2,
            y: (bounds.height - panelH) / 2,
            width: panelW,
            height: panelH
        )
        browserFrame = panelFrame
        panel.frame = panelFrame
        webView.frame = panel.bounds.insetBy(dx: 2, dy: 2)
        panel.transform = panelTransform
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    func webPoint(fromEyePoint point: CGPoint) -> CGPoint? {
        let panelPoint = panel.convert(point, from: self)
        guard panel.bounds.contains(panelPoint) else { return nil }
        let x = (panelPoint.x / max(panel.bounds.width, 1)) * webView.bounds.width
        let y = (panelPoint.y / max(panel.bounds.height, 1)) * webView.bounds.height
        return CGPoint(x: x, y: y)
    }

    func setWorldProjection(globalCenter: CGPoint, in rootView: UIView, scale: CGFloat, rotation: CGFloat) {
        let localCenter = convert(globalCenter, from: rootView)
        let baseCenter = browserFrame.midPoint
        panelTransform = CGAffineTransform(translationX: localCenter.x - baseCenter.x, y: localCenter.y - baseCenter.y)
            .rotated(by: rotation)
            .scaledBy(x: scale, y: scale)
        panel.transform = panelTransform
    }

    func resetHeadOffset() {
        panelTransform = .identity
        panel.transform = .identity
    }
}

final class CursorView: UIView {
    private let dot = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        isUserInteractionEnabled = false

        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        layer.cornerRadius = 10
        dot.backgroundColor = UIColor.white
        dot.layer.cornerRadius = 3
        addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = CGRect(x: bounds.midX - 2.5, y: bounds.midY - 2.5, width: 5, height: 5)
    }

    func setPressed(_ pressed: Bool) {
        alpha = pressed ? 1 : 0.78
        transform = pressed ? CGAffineTransform(scaleX: 1.18, y: 1.18) : .identity
    }
}

final class LensMaskView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.58).cgColor)
        ctx.fill(rect)

        let landscape = rect.width >= rect.height
        let holeRects: [CGRect]
        if landscape {
            let holeW = rect.width * 0.40
            let holeH = rect.height * 0.70
            let gap = rect.width * 0.045
            holeRects = [
                CGRect(x: rect.midX - gap / 2 - holeW, y: rect.midY - holeH / 2, width: holeW, height: holeH),
                CGRect(x: rect.midX + gap / 2, y: rect.midY - holeH / 2, width: holeW, height: holeH)
            ]
        } else {
            let holeW = rect.width * 0.70
            let holeH = rect.height * 0.40
            let gap = rect.height * 0.045
            holeRects = [
                CGRect(x: rect.midX - holeW / 2, y: rect.midY - gap / 2 - holeH, width: holeW, height: holeH),
                CGRect(x: rect.midX - holeW / 2, y: rect.midY + gap / 2, width: holeW, height: holeH)
            ]
        }

        ctx.setBlendMode(.clear)
        for r in holeRects {
            ctx.fillEllipse(in: r)
        }
    }
}

final class MainMenuView: UIView {
    var onEnter: (() -> Void)?
    private let titleLabel = UILabel()
    private let enterButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        titleLabel.text = "HandAR Vision"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 31, weight: .medium)
        titleLabel.textAlignment = .center
        addSubview(titleLabel)

        enterButton.setTitle("ВОЙТИ В AR", for: .normal)
        enterButton.setTitleColor(.white, for: .normal)
        enterButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        enterButton.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        enterButton.layer.cornerRadius = 22
        enterButton.layer.borderWidth = 1
        enterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
        enterButton.addAction(UIAction { [weak self] _ in self?.onEnter?() }, for: .touchUpInside)
        addSubview(enterButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = CGRect(x: 24, y: bounds.midY - 85, width: bounds.width - 48, height: 46)
        enterButton.frame = CGRect(x: max(24, bounds.midX - 140), y: bounds.midY - 20, width: min(280, bounds.width - 48), height: 58)
    }
}
