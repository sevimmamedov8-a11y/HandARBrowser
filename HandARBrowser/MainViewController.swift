import UIKit
import AVFoundation
import Vision
import WebKit
import CoreMotion

final class MainViewController: UIViewController {
    private let camera = CameraManager()
    private let motion = MotionTracker()
    private let hands = HandTracker()
    private let input = WebInputBridge()

    private var leftPreview: AVCaptureVideoPreviewLayer!
    private var rightPreview: AVCaptureVideoPreviewLayer!

    private let leftEye = EyeContainer(hand: .left)
    private let rightEye = EyeContainer(hand: .right)

    private let cursorLeftA = CursorView(title: "L")
    private let cursorLeftB = CursorView(title: "L")
    private let cursorRightA = CursorView(title: "R")
    private let cursorRightB = CursorView(title: "R")
    private let hud = HUDView()
    private let startPanel = StartPanel()

    private var lastSize: CGSize = .zero
    private var started = false

    override var prefersStatusBarHidden: Bool { true }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        leftEye.webView.navigationDelegate = self
        rightEye.webView.navigationDelegate = self
        input.mirror = [leftEye.webView, rightEye.webView]
        leftEye.webView.uiDelegate = self
        rightEye.webView.uiDelegate = self

        leftPreview = AVCaptureVideoPreviewLayer(session: camera.session)
        rightPreview = AVCaptureVideoPreviewLayer(session: camera.session)
        leftPreview.videoGravity = .resizeAspectFill
        rightPreview.videoGravity = .resizeAspectFill
        leftPreview.connection?.videoOrientation = .landscapeRight
        rightPreview.connection?.videoOrientation = .landscapeRight
        view.layer.addSublayer(leftPreview)
        view.layer.addSublayer(rightPreview)

        view.addSubview(leftEye)
        view.addSubview(rightEye)
        view.addSubview(cursorLeftA)
        view.addSubview(cursorLeftB)
        view.addSubview(cursorRightA)
        view.addSubview(cursorRightB)
        view.addSubview(hud)
        view.addSubview(startPanel)

        startPanel.onStart = { [weak self] url in
            self?.start(url: url)
        }
        hud.onRecenter = { [weak self] in self?.motion.calibrate() }
        hud.onToggleBrowser = { [weak self] in self?.toggleBrowser() }

        hands.onUpdate = { [weak self] left, right in
            self?.handleHands(left: left, right: right)
        }
        motion.onUpdate = { [weak self] pose in
            self?.handleHead(pose)
        }

        camera.onPermissionDenied = { [weak self] in
            DispatchQueue.main.async {
                self?.showMessage("Камера запрещена. Настройки → Hand AR Browser → Камера")
            }
        }

        camera.onFrame = { [weak self] sampleBuffer, orientation in
            self?.hands.process(sampleBuffer: sampleBuffer, orientation: orientation)
        }

        camera.prepare()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize else { return }
        lastSize = view.bounds.size

        let w = view.bounds.width
        let h = view.bounds.height
        let half = w / 2
        leftPreview.frame = CGRect(x: 0, y: 0, width: half, height: h)
        rightPreview.frame = CGRect(x: half, y: 0, width: half, height: h)
        if let c = leftPreview.connection, c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        if let c = rightPreview.connection, c.isVideoOrientationSupported { c.videoOrientation = .landscapeRight }
        leftEye.frame = CGRect(x: 0, y: 0, width: half, height: h)
        rightEye.frame = CGRect(x: half, y: 0, width: half, height: h)
        for cursor in [cursorLeftA, cursorLeftB, cursorRightA, cursorRightB] { cursor.frame.size = CGSize(width: 36, height: 36) }
        hud.frame = CGRect(x: 18, y: 18, width: min(360, w - 36), height: 42)
        startPanel.frame = CGRect(x: 0, y: 0, width: w, height: h)
    }

    private func start(url: URL) {
        guard !started else { return }
        started = true
        startPanel.isHidden = true
        hud.isHidden = false

        leftEye.load(url: url)
        rightEye.load(url: url)
        camera.start()
        motion.start()
        motion.calibrate()
    }

    private func handleHead(_ pose: HeadPose) {
        // Opposite transform makes the browser behave like a world-locked panel
        // while the camera itself rotates with the phone.
        let yaw = clamp(pose.yaw * 4.8, -0.42, 0.42)
        let pitch = clamp(pose.pitch * 4.0, -0.30, 0.30)
        let roll = clamp(-pose.roll, -0.18, 0.18)
        let dx = -CGFloat(yaw) * 170
        let dy = CGFloat(pitch) * 120

        leftEye.setHeadOffset(dx: dx - 3, dy: dy, roll: roll)
        rightEye.setHeadOffset(dx: dx + 3, dy: dy, roll: roll)
    }

    private func handleHands(left: HandSample?, right: HandSample?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateCursor(sample: left, cursors: [self.cursorLeftA, self.cursorLeftB], eye: self.leftEye, pointerID: 1)
            self.updateCursor(sample: right, cursors: [self.cursorRightA, self.cursorRightB], eye: self.rightEye, pointerID: 2)
        }
    }

    private func updateCursor(sample: HandSample?, cursors: [CursorView], eye: EyeContainer, pointerID: Int) {
        guard let sample else {
            cursors.forEach { $0.isHidden = true }
            input.release(pointerID: pointerID, webView: eye.webView)
            return
        }

        let leftScreenPoint = cameraPointToScreen(sample.indexTip, eyeIndex: 0)
        let rightScreenPoint = cameraPointToScreen(sample.indexTip, eyeIndex: 1)
        cursors[0].isHidden = false
        cursors[1].isHidden = false
        cursors[0].center = leftScreenPoint
        cursors[1].center = rightScreenPoint
        cursors.forEach { $0.setPressed(sample.isPinching) }

        let screenPoint = eye === leftEye ? leftScreenPoint : rightScreenPoint
        let local = eye.convert(screenPoint, from: view)
        let panelRect = eye.browserFrame
        guard panelRect.contains(local) else {
            input.release(pointerID: pointerID, webView: eye.webView)
            return
        }

        let webLocal = CGPoint(x: local.x - panelRect.minX, y: local.y - panelRect.minY)
        let webPoint = CGPoint(x: webLocal.x / panelRect.width * eye.webView.bounds.width,
                               y: webLocal.y / panelRect.height * eye.webView.bounds.height)
        input.update(pointerID: pointerID,
                     point: webPoint,
                     pinch: sample.isPinching,
                     webView: eye.webView)
    }

    private func cameraPointToScreen(_ p: CGPoint, eyeIndex: Int) -> CGPoint {
        // Vision is normalized with origin at lower-left. Both eyes receive the
        // full rear-camera image; each eye is a copy of the same camera view.
        let screen = view.bounds.size
        let halfW = screen.width / 2
        let eye = eyeIndex
        let viewW = halfW
        let viewH = screen.height

        let imageAspect: CGFloat = 16.0 / 9.0
        let viewAspect = viewW / viewH
        let scale: CGFloat
        let drawW: CGFloat
        let drawH: CGFloat
        let cropX: CGFloat
        let cropY: CGFloat

        if imageAspect > viewAspect {
            scale = viewH / 1080.0
            drawW = 1920.0 * scale
            drawH = viewH
            cropX = (drawW - viewW) / 2
            cropY = 0
        } else {
            scale = viewW / 1920.0
            drawW = viewW
            drawH = 1080.0 * scale
            cropX = 0
            cropY = (drawH - viewH) / 2
        }

        let xInEye = p.x * drawW - cropX
        let yInEye = (1.0 - p.y) * drawH - cropY
        let x = CGFloat(eye) * halfW + xInEye
        let y = yInEye
        return CGPoint(x: clamp(x, 0, screen.width), y: clamp(y, 0, screen.height))
    }

    private func toggleBrowser() {
        leftEye.isHidden.toggle()
        rightEye.isHidden = leftEye.isHidden
        hud.setBrowserVisible(!leftEye.isHidden)
    }

    private func showMessage(_ text: String) {
        let alert = UIAlertController(title: "Hand AR Browser", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func clamp(_ value: Double, _ min: Double, _ max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }

    private func clamp(_ value: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }
}

extension MainViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let other = (webView === leftEye.webView) ? rightEye.webView : leftEye.webView
        guard other.url?.absoluteString != url.absoluteString else { return }
        other.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

struct HeadPose {
    let yaw: Double
    let pitch: Double
    let roll: Double
}

struct HandSample {
    let chirality: VNChirality
    let indexTip: CGPoint
    let thumbTip: CGPoint
    let confidence: VNConfidence
    let isPinching: Bool
}

@inline(__always) private func smooth(_ old: CGPoint?, _ new: CGPoint, alpha: CGFloat) -> CGPoint {
    guard let old else { return new }
    return CGPoint(x: old.x + (new.x - old.x) * alpha,
                   y: old.y + (new.y - old.y) * alpha)
}

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "handar.camera", qos: .userInteractive)
    private var output: AVCaptureVideoDataOutput?
    private var configured = false
    var onFrame: ((CMSampleBuffer, CGImagePropertyOrientation) -> Void)?
    var onPermissionDenied: (() -> Void)?

    func prepare() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            if allowed {
                self.queue.async { self.configure() }
            } else {
                self.onPermissionDenied?()
            }
        }
    }

    private func configure() {
        guard !configured,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        do {
            try device.lockForConfiguration()
            let frame = CMTime(value: 1, timescale: 60)
            if device.activeVideoMinFrameDuration.timescale > 0 {
                device.activeVideoMinFrameDuration = frame
                device.activeVideoMaxFrameDuration = frame
            }
            device.unlockForConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            self.output = output

            if let connection = output.connection(with: .video) {
                if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
                connection.videoMirrored = false
            }
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer, .right)
    }
}

final class MotionTracker {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = { let q = OperationQueue(); q.qualityOfService = .userInteractive; return q }()
    private var reference: CMAttitude?
    private let lock = NSLock()
    var onUpdate: ((HeadPose) -> Void)?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 120.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.lock.lock()
            let ref = self.reference
            self.lock.unlock()

            if let ref {
                let relative = motion.attitude.copy() as! CMAttitude
                relative.multiply(byInverseOf: ref)
                let yaw = relative.yaw
                let pitch = relative.pitch
                let roll = relative.roll
                self.onUpdate?(HeadPose(yaw: yaw, pitch: pitch, roll: roll))
            }
        }
    }

    func calibrate() {
        guard let current = manager.deviceMotion?.attitude else { return }
        lock.lock()
        reference = current.copy() as? CMAttitude
        lock.unlock()
    }
}

final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private let queue = DispatchQueue(label: "handar.vision", qos: .userInteractive)
    private let gate = DispatchSemaphore(value: 1)
    private var lastLeft: CGPoint?
    private var lastRight: CGPoint?
    var onUpdate: ((HandSample?, HandSample?) -> Void)?

    func process(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard gate.wait(timeout: .now()) == .success else { return }
        queue.async { [weak self] in
            guard let self else { gate.signal(); return }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([self.request])
                let observations = self.request.results ?? []
                var left: HandSample?
                var right: HandSample?
                for obs in observations {
                    guard let index = try? obs.recognizedPoint(.indexTip),
                          let thumb = try? obs.recognizedPoint(.thumbTip),
                          index.confidence > 0.35,
                          thumb.confidence > 0.35 else { continue }

                    let prev = obs.chirality == .left ? self.lastLeft : self.lastRight
                    let filtered = smooth(prev, index.location, alpha: 0.42)
                    if obs.chirality == .left { self.lastLeft = filtered }
                    else if obs.chirality == .right { self.lastRight = filtered }

                    let pinchDistance = hypot(index.location.x - thumb.location.x, index.location.y - thumb.location.y)
                    let sample = HandSample(chirality: obs.chirality,
                                            indexTip: filtered,
                                            thumbTip: thumb.location,
                                            confidence: min(index.confidence, thumb.confidence),
                                            isPinching: pinchDistance < 0.055)
                    if obs.chirality == .left { left = sample }
                    if obs.chirality == .right { right = sample }
                }
                self.onUpdate?(left, right)
            } catch { }
            gate.signal()
        }
    }
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
                let script = "window.scrollBy(0, \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), deltaY * 2.8)));"
                mirror.filter { $0 !== webView }.forEach { dispatch(script, to: $0) }
                dispatch(script, to: webView)
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
        states[pointerID] = state
    }

    private func dispatch(_ script: String, to webView: WKWebView) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

final class EyeContainer: UIView {
    enum HandSide { case left, right }
    let webView: WKWebView
    private let chrome = UIView()
    private let titleLabel = UILabel()
    private var baseTransform: CGAffineTransform = .identity
    private(set) var browserFrame: CGRect = .zero

    init(hand: HandSide) {
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
        clipsToBounds = true
        backgroundColor = .clear

        chrome.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        chrome.layer.cornerRadius = 10
        addSubview(chrome)
        addSubview(webView)

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.text = hand == .left ? "LEFT EYE" : "RIGHT EYE"
        chrome.addSubview(titleLabel)

        let border = CAShapeLayer()
        border.strokeColor = UIColor.white.withAlphaComponent(0.22).cgColor
        border.fillColor = UIColor.clear.cgColor
        border.lineWidth = 1
        layer.addSublayer(border)

        webView.isOpaque = true
        webView.backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let marginX = bounds.width * 0.08
        let marginY = bounds.height * 0.08
        browserFrame = CGRect(x: marginX, y: marginY, width: bounds.width - 2 * marginX, height: bounds.height - 2 * marginY)
        webView.frame = browserFrame
        chrome.frame = CGRect(x: browserFrame.minX, y: browserFrame.minY - 30, width: browserFrame.width, height: 26)
        titleLabel.frame = chrome.bounds.insetBy(dx: 8, dy: 2)
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    func setHeadOffset(dx: CGFloat, dy: CGFloat, roll: CGFloat) {
        let t = CGAffineTransform(translationX: dx, y: dy).rotated(by: roll)
        transform = baseTransform.concatenating(t)
    }
}

final class CursorView: UIView {
    private let label = UILabel()
    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = 18
        isUserInteractionEnabled = false
        isHidden = true
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textAlignment = .center
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { label.frame = bounds }
    func setPressed(_ pressed: Bool) {
        alpha = pressed ? 0.95 : 0.65
        layer.borderColor = (pressed ? UIColor.systemGreen : UIColor.white).cgColor
    }
}

final class HUDView: UIView {
    var onRecenter: (() -> Void)?
    var onToggleBrowser: (() -> Void)?
    private let recenter = UIButton(type: .system)
    private let toggle = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.65)
        layer.cornerRadius = 10
        recenter.setTitle("CENTER", for: .normal)
        toggle.setTitle("BROWSER", for: .normal)
        recenter.tintColor = .white
        toggle.tintColor = .white
        addSubview(recenter); addSubview(toggle)
        recenter.addAction(UIAction { [weak self] _ in self?.onRecenter?() }, for: .touchUpInside)
        toggle.addAction(UIAction { [weak self] _ in self?.onToggleBrowser?() }, for: .touchUpInside)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        let half = bounds.width / 2
        recenter.frame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
        toggle.frame = CGRect(x: half, y: 0, width: half, height: bounds.height)
    }
    func setBrowserVisible(_ visible: Bool) {
        toggle.setTitle(visible ? "BROWSER" : "BROWSER OFF", for: .normal)
    }
}

final class StartPanel: UIView {
    var onStart: ((URL) -> Void)?
    private let title = UILabel()
    private let field = UITextField()
    private let button = UIButton(type: .system)
    private let note = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.82)

        title.text = "HAND AR BROWSER"
        title.textColor = .white
        title.font = .systemFont(ofSize: 32, weight: .bold)
        title.textAlignment = .center

        field.text = "https://www.google.com"
        field.textColor = .white
        field.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        field.layer.cornerRadius = 12
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .URL
        field.returnKeyType = .go
        field.placeholder = "URL"

        button.setTitle("START", for: .normal)
        button.tintColor = .white
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        button.layer.cornerRadius = 12

        note.text = "Вставь телефон в очки. Камера должна смотреть наружу.\nУказательный = курсор • щипок = клик/перетаскивание • CENTER = калибровка"
        note.numberOfLines = 0
        note.textAlignment = .center
        note.textColor = UIColor.white.withAlphaComponent(0.75)
        note.font = .systemFont(ofSize: 14)

        addSubview(title); addSubview(field); addSubview(button); addSubview(note)
        button.addAction(UIAction { [weak self] _ in self?.start() }, for: .touchUpInside)
        field.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        let w = bounds.width
        title.frame = CGRect(x: w*0.18, y: bounds.height*0.20, width: w*0.64, height: 45)
        field.frame = CGRect(x: w*0.25, y: bounds.height*0.38, width: w*0.50, height: 52)
        button.frame = CGRect(x: w*0.35, y: bounds.height*0.54, width: w*0.30, height: 52)
        note.frame = CGRect(x: w*0.18, y: bounds.height*0.67, width: w*0.64, height: 70)
    }
    private func start() {
        let raw = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://\(raw)"
        guard let url = URL(string: value) else { return }
        endEditing(true)
        onStart?(url)
    }
}

extension StartPanel: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { start(); return true }
}
