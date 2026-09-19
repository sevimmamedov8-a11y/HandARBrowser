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
    private var worldARAnchor: ARAnchor?
    private var realityWorldAnchor: AnchorEntity?
    private var lastCenterGestureTime = CACurrentMediaTime()

    // Small floating AR browser, deliberately farther away and smaller for a glasses-like field of view.
    private let browserWorldWidth: Float = 0.62
    private let browserWorldHeight: Float = 0.36
    private let browserWorldDistance: Float = 1.55
    private let stereoGap: Float = 0.014
    private let eyeSeparation: Float = 0.062

    override var prefersStatusBarHidden: Bool { true }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        inAR ? .landscapeRight : .all
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
        guard view.bounds.size != lastSize else {
            updateInterfaceOrientation()
            return
        }
        lastSize = view.bounds.size

        arView.frame = view.bounds
        menu.frame = view.bounds
        lensMask.frame = view.bounds

        // The physical goggles have two side-by-side lenses. Never stack the eye views vertically.
        let half = view.bounds.width * 0.5
        eyeLeft.frame = CGRect(x: 0, y: 0, width: half, height: view.bounds.height)
        eyeRight.frame = CGRect(x: half, y: 0, width: half, height: view.bounds.height)

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
        worldARAnchor = nil
        realityWorldAnchor?.removeFromParent()
        realityWorldAnchor = nil
        setNeedsUpdateOfSupportedInterfaceOrientations()
        requestLandscapeMode()
        tracking.setInterfaceOrientation(.landscapeRight)
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
        worldARAnchor = nil
        realityWorldAnchor?.removeFromParent()
        realityWorldAnchor = nil
        setNeedsUpdateOfSupportedInterfaceOrientations()
        requestAnyOrientation()
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
        view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .landscapeRight
    }

    private func requestLandscapeMode() {
        guard let windowScene = view.window?.windowScene else { return }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight), errorHandler: nil)
    }

    private func requestAnyOrientation() {
        guard let windowScene = view.window?.windowScene else { return }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .all), errorHandler: nil)
    }

    private func updateInterfaceOrientation() {
        tracking.setInterfaceOrientation(currentInterfaceOrientation)
    }

    private func applyARPose(_ pose: ARPose) {
        guard inAR, view.bounds.width > view.bounds.height else { return }

        if worldBrowserAnchor == nil {
            let transform = pose.transform
            let cameraPosition = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let cameraRight = simd_normalize(SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
            let cameraUp = simd_normalize(SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
            let cameraForward = simd_normalize(-SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
            let center = cameraPosition + cameraForward * browserWorldDistance
            worldBrowserAnchor = WorldBrowserAnchor(center: center, right: cameraRight, up: cameraUp)

            // Register a real ARKit world anchor at the exact placement point.
            var anchorTransform = transform
            anchorTransform.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
            worldARAnchor = tracking.addAnchor(transform: anchorTransform)

            // RealityKit also receives the same world transform. The glass frame is a real
            // 3D entity in the AR scene, so it remains at the original room-space location
            // instead of being a simple 2D screen overlay.
            let rkAnchor = AnchorEntity(world: anchorTransform)
            rkAnchor.addChild(Self.makeBrowserFrameEntity(width: browserWorldWidth, height: browserWorldHeight))
            arView.scene.addAnchor(rkAnchor)
            realityWorldAnchor = rkAnchor
        }

        // Reproject the fixed world-space plane from the current tracked camera pose.
        // The browser therefore moves against the camera with real AR parallax instead of
        // simply scaling around the middle of the screen.
        reprojectWorldBrowser()
    }

    private func projectEye(
        eye: EyeContainer,
        worldCenter: SIMD3<Float>,
        worldRight: SIMD3<Float>,
        worldUp: SIMD3<Float>,
        halfWidth: Float,
        halfHeight: Float,
        eyeOffset: Float
    ) {
        guard eye.bounds.width > 1, eye.bounds.height > 1 else { return }
        let viewport = eye.bounds.size
        guard
            let topLeft = tracking.projectWorldPoint(worldCenter - worldRight * halfWidth + worldUp * halfHeight, viewportSize: viewport, eyeOffset: eyeOffset),
            let topRight = tracking.projectWorldPoint(worldCenter + worldRight * halfWidth + worldUp * halfHeight, viewportSize: viewport, eyeOffset: eyeOffset),
            let bottomLeft = tracking.projectWorldPoint(worldCenter - worldRight * halfWidth - worldUp * halfHeight, viewportSize: viewport, eyeOffset: eyeOffset),
            let bottomRight = tracking.projectWorldPoint(worldCenter + worldRight * halfWidth - worldUp * halfHeight, viewportSize: viewport, eyeOffset: eyeOffset)
        else { return }

        // The projected rectangle is converted into an affine screen-space plane.
        // This retains parallax + tilt instead of applying only uniform scale.
        eye.setWorldQuadrilateral(topLeft: topLeft, topRight: topRight, bottomLeft: bottomLeft, bottomRight: bottomRight)
    }

    private func applyReferencePoseIfPossible() {
        reprojectWorldBrowser()
    }

    private func reprojectWorldBrowser() {
        guard inAR, let anchor = worldBrowserAnchor else { return }

        let eyePanelWidth = max((browserWorldWidth - stereoGap) * 0.5, 0.05)
        let halfHeight = browserWorldHeight * 0.5
        let halfEyeWidth = eyePanelWidth * 0.5
        let eyeShift = eyeSeparation * 0.5

        let leftCenter = anchor.center - anchor.right * (stereoGap * 0.5 + halfEyeWidth)
        let rightCenter = anchor.center + anchor.right * (stereoGap * 0.5 + halfEyeWidth)

        projectEye(eye: eyeLeft, worldCenter: leftCenter, worldRight: anchor.right, worldUp: anchor.up, halfWidth: halfEyeWidth, halfHeight: halfHeight, eyeOffset: +eyeShift)
        projectEye(eye: eyeRight, worldCenter: rightCenter, worldRight: anchor.right, worldUp: anchor.up, halfWidth: halfEyeWidth, halfHeight: halfHeight, eyeOffset: -eyeShift)
    }

    private static func makeBrowserFrameEntity(width: Float, height: Float) -> Entity {
        let root = Entity()
        let thickness: Float = 0.006
        let depth: Float = 0.008
        let material = UnlitMaterial(color: UIColor.white.withAlphaComponent(0.16))

        let top = ModelEntity(
            mesh: MeshResource.generateBox(size: [width, thickness, depth], cornerRadius: thickness * 0.35),
            materials: [material]
        )
        top.position = [0, height * 0.5, 0]

        let bottom = ModelEntity(
            mesh: MeshResource.generateBox(size: [width, thickness, depth], cornerRadius: thickness * 0.35),
            materials: [material]
        )
        bottom.position = [0, -height * 0.5, 0]

        let left = ModelEntity(
            mesh: MeshResource.generateBox(size: [thickness, height, depth], cornerRadius: thickness * 0.35),
            materials: [material]
        )
        left.position = [-width * 0.5, 0, 0]

        let right = ModelEntity(
            mesh: MeshResource.generateBox(size: [thickness, height, depth], cornerRadius: thickness * 0.35),
            materials: [material]
        )
        right.position = [width * 0.5, 0, 0]

        root.addChild(top)
        root.addChild(bottom)
        root.addChild(left)
        root.addChild(right)
        return root
    }

    private func handleHands(left: HandSample?, right: HandSample?) {
        guard inAR else { return }

        if left?.isPinching == true && right?.isPinching == true {
            let now = CACurrentMediaTime()
            if now - lastCenterGestureTime > 1.0 {
                lastCenterGestureTime = now
                worldBrowserAnchor = nil
                worldARAnchor = nil
                realityWorldAnchor?.removeFromParent()
                realityWorldAnchor = nil
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
        point.x < view.bounds.midX ? eyeLeft : eyeRight
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

// V22_BUILD_FIX_MARKER: use simd_normalize for ARKit vector normalization.
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

    @discardableResult
    func addAnchor(transform: simd_float4x4) -> ARAnchor {
        let anchor = ARAnchor(transform: transform)
        session.add(anchor: anchor)
        return anchor
    }

    func projectWorldPoint(_ worldPoint: SIMD3<Float>, viewportSize: CGSize, eyeOffset: Float = 0) -> CGPoint? {
        frameLock.lock()
        let frame = latestFrame
        let orientation = interfaceOrientation
        frameLock.unlock()
        guard let frame else { return nil }

        // Render each eye from a tiny virtual camera offset along the tracked camera-right axis.
        let cameraTransform = frame.camera.transform
        let cameraRight = simd_normalize(SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z))
        let eyeAdjustedPoint = worldPoint + cameraRight * eyeOffset
        let point = frame.camera.projectPoint(eyeAdjustedPoint, orientation: orientation, viewportSize: viewportSize)
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
        if let latest = VNDetectHumanHandPoseRequest.supportedRevisions.max(), latest >= r.revision {
            r.revision = latest
        }
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
                        index.confidence > 0.60,
                        thumb.confidence > 0.55,
                        wrist.confidence > 0.40,
                        middleMCP.confidence > 0.40
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
    // Strong smoothing while stationary, with a faster response for deliberate movement.
    return min(0.78, max(0.22, 0.22 + jump * 1.70))
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
        let panelW = bounds.width * 0.68
        let panelH = bounds.height * 0.46
        let panelFrame = CGRect(
            x: (bounds.width - panelW) / 2,
            y: (bounds.height - panelH) / 2,
            width: panelW,
            height: panelH
        )
        browserFrame = panelFrame

        // Use a top-left anchor point so the world-projected affine transform maps
        // directly from the web canvas to the tracked quadrilateral.
        panel.layer.anchorPoint = .zero
        panel.bounds = CGRect(origin: .zero, size: panelFrame.size)
        panel.layer.position = panelFrame.origin
        panelTransform = .identity
        panel.layer.setAffineTransform(.identity)
        webView.frame = panel.bounds.insetBy(dx: 2, dy: 2)
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

    func setWorldQuadrilateral(topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) {
        let w = max(browserFrame.width, 1)
        let h = max(browserFrame.height, 1)

        let a = (topRight.x - topLeft.x) / w
        let b = (topRight.y - topLeft.y) / w
        let c = (bottomLeft.x - topLeft.x) / h
        let d = (bottomLeft.y - topLeft.y) / h
        panel.layer.position = topLeft
        panelTransform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: 0, ty: 0)
        panel.layer.setAffineTransform(panelTransform)
    }

    func resetHeadOffset() {
        panelTransform = .identity
        panel.layer.setAffineTransform(.identity)
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
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.62).cgColor)
        ctx.fill(rect)

        // Physical goggles always expose two side-by-side oval apertures.
        let holeW = rect.width * 0.425
        let holeH = rect.height * 0.74
        let gap = rect.width * 0.030
        let holeRects = [
            CGRect(x: rect.midX - gap * 0.5 - holeW, y: rect.midY - holeH * 0.5, width: holeW, height: holeH),
            CGRect(x: rect.midX + gap * 0.5, y: rect.midY - holeH * 0.5, width: holeW, height: holeH)
        ]

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
