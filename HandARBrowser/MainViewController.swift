import UIKit
import AVFoundation
import Vision
import WebKit
import CoreMotion

private func configurePreviewRotation(_ connection: AVCaptureConnection?, orientation: UIInterfaceOrientation) {
    guard let connection else { return }
    let angle: CGFloat
    switch orientation {
    case .landscapeLeft:
        angle = 270
    case .landscapeRight:
        angle = 90
    default:
        angle = 90
    }
    if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        backgroundColor = .black
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MainViewController: UIViewController {
    private let camera = CameraManager()
    private let motion = MotionTracker()
    private let hands = HandTracker()
    private let input = WebInputBridge()

    private var cameraView: CameraPreviewView!
    private let eyeLeft = EyeContainer(title: "LEFT")
    private let eyeRight = EyeContainer(title: "RIGHT")
    private let cursorLeft = CursorView()
    private let cursorRight = CursorView()
    private let hud = HUDView()
    private let addressField = UITextField()
    private let goButton = UIButton(type: .system)

    private var lastSize: CGSize = .zero
    private var lastCameraFrame = CACurrentMediaTime()
    private var browserVisible = true
    private var started = false

    override var prefersStatusBarHidden: Bool { true }
    override var shouldAutorotate: Bool { false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        wireServices()
        registerCameraNotifications()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        camera.prepareAndStart()
        motion.start()
        motion.calibrate()
        eyeLeft.load(url: Self.homeURL)
        eyeRight.load(url: Self.homeURL)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize else {
            updatePreviewRotation()
            return
        }
        lastSize = view.bounds.size

        cameraView.frame = view.bounds

        let w = view.bounds.width
        let h = view.bounds.height
        let half = w / 2
        eyeLeft.frame = CGRect(x: 0, y: 0, width: half, height: h)
        eyeRight.frame = CGRect(x: half, y: 0, width: half, height: h)

        hud.frame = CGRect(x: 18, y: 16, width: min(430, w - 36), height: 42)
        addressField.frame = CGRect(x: max(20, w - 360), y: 16, width: 286, height: 42)
        goButton.frame = CGRect(x: w - 64, y: 16, width: 44, height: 42)
        cursorLeft.frame.size = CGSize(width: 34, height: 34)
        cursorRight.frame.size = CGSize(width: 34, height: 34)

        updatePreviewRotation()
    }

    private static let homeURL = URL(string: "https://www.google.com/")!

    private func buildInterface() {
        view.backgroundColor = .black

        cameraView = CameraPreviewView(session: camera.session)
        view.addSubview(cameraView)

        eyeLeft.alpha = 0.94
        eyeRight.alpha = 0.94
        view.addSubview(eyeLeft)
        view.addSubview(eyeRight)

        cursorLeft.isHidden = true
        cursorRight.isHidden = true
        view.addSubview(cursorLeft)
        view.addSubview(cursorRight)

        setupHud()
        setupAddressBar()
        hud.bringSubviewToFront(in: view)
        addressField.bringSubviewToFront(in: view)
        goButton.bringSubviewToFront(in: view)
        cursorLeft.bringSubviewToFront(in: view)
        cursorRight.bringSubviewToFront(in: view)
    }

    private func setupHud() {
        hud.statusText.text = "КАМЕРА • ЗАПУСК..."
        hud.onCenter = { [weak self] in
            self?.motion.calibrate()
            self?.hud.setStatus("CENTER • OK")
        }
        hud.onBrowser = { [weak self] in
            guard let self else { return }
            self.browserVisible.toggle()
            self.eyeLeft.isHidden = !self.browserVisible
            self.eyeRight.isHidden = !self.browserVisible
            self.hud.setBrowserVisible(self.browserVisible)
        }
        hud.onCamera = { [weak self] in
            self?.camera.requestStartAgain()
        }
        view.addSubview(hud)
    }

    private func setupAddressBar() {
        addressField.text = Self.homeURL.absoluteString
        addressField.placeholder = "https://..."
        addressField.textColor = .white
        addressField.tintColor = .systemYellow
        addressField.font = .systemFont(ofSize: 13, weight: .medium)
        addressField.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        addressField.layer.cornerRadius = 10
        addressField.layer.borderWidth = 1
        addressField.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.keyboardType = .URL
        addressField.returnKeyType = .go
        addressField.delegate = self
        view.addSubview(addressField)

        goButton.setTitle("GO", for: .normal)
        goButton.tintColor = .white
        goButton.backgroundColor = UIColor.black.withAlphaComponent(0.70)
        goButton.layer.cornerRadius = 10
        goButton.layer.borderWidth = 1
        goButton.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        goButton.addAction(UIAction { [weak self] _ in self?.loadAddress() }, for: .touchUpInside)
        view.addSubview(goButton)
    }

    private func wireServices() {
        eyeLeft.webView.navigationDelegate = self
        eyeRight.webView.navigationDelegate = self
        eyeLeft.webView.uiDelegate = self
        eyeRight.webView.uiDelegate = self
        input.mirror = [eyeLeft.webView, eyeRight.webView]

        camera.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.hud.setStatus(text) }
        }
        camera.onFrame = { [weak self] sampleBuffer, orientation in
            guard let self else { return }
            self.lastCameraFrame = CACurrentMediaTime()
            self.hands.process(sampleBuffer: sampleBuffer, orientation: orientation)
        }
        camera.onConfigurationFailed = { [weak self] reason in
            DispatchQueue.main.async { self?.hud.setStatus("КАМЕРА • ОШИБКА") ; self?.showCameraAlert(reason) }
        }
        camera.onPermissionDenied = { [weak self] in
            DispatchQueue.main.async {
                self?.hud.setStatus("КАМЕРА • НЕТ ДОСТУПА")
                self?.showCameraAlert("Разреши камеру в Настройки → HandAR Vision → Камера.")
            }
        }

        hands.onUpdate = { [weak self] left, right in
            guard let self else { return }
            DispatchQueue.main.async {
                self.updateCursor(left, view: self.cursorLeft, pointerID: 1)
                self.updateCursor(right, view: self.cursorRight, pointerID: 2)
            }
        }

        motion.onUpdate = { [weak self] pose in
            DispatchQueue.main.async {
                self?.applyHeadPose(pose)
            }
        }
    }

    private func registerCameraNotifications() {
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: camera.session, queue: .main) { [weak self] note in
            let error = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Неизвестная ошибка"
            self?.hud.setStatus("КАМЕРА • ERROR")
            self?.showCameraAlert(error)
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: camera.session, queue: .main) { [weak self] _ in
            self?.hud.setStatus("КАМЕРА • ПРИОСТАНОВЛЕНА")
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: camera.session, queue: .main) { [weak self] _ in
            self?.hud.setStatus("КАМЕРА • ВОССТАНОВЛЕНИЕ")
            self?.camera.requestStartAgain()
        }
    }

    private func updatePreviewRotation() {
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
        configurePreviewRotation(cameraView.previewLayer.connection, orientation: orientation)
    }

    private func updateCursor(_ sample: HandSample?, view cursorView: CursorView, pointerID: Int) {
        guard let sample else {
            cursorView.isHidden = true
            let target = pointerID == 1 ? eyeLeft.webView : eyeRight.webView
            input.release(pointerID: pointerID, webView: target)
            return
        }

        let devicePoint = CGPoint(x: sample.indexTip.x, y: 1.0 - sample.indexTip.y)
        let point = cameraView.previewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
        cursorView.isHidden = false
        cursorView.center = point
        cursorView.setPressed(sample.isPinching)

        let half = view.bounds.width / 2
        if point.x < half {
            sendPointer(point: point, eye: eyeLeft, pointerID: pointerID, pinch: sample.isPinching)
        } else {
            sendPointer(point: CGPoint(x: point.x - half, y: point.y), eye: eyeRight, pointerID: pointerID, pinch: sample.isPinching)
        }
    }

    private func sendPointer(point: CGPoint, eye: EyeContainer, pointerID: Int, pinch: Bool) {
        let panel = eye.browserFrame
        guard panel.contains(point) else {
            input.release(pointerID: pointerID, webView: eye.webView)
            return
        }
        let x = ((point.x - panel.minX) / max(panel.width, 1)) * eye.webView.bounds.width
        let y = ((point.y - panel.minY) / max(panel.height, 1)) * eye.webView.bounds.height
        input.update(pointerID: pointerID, point: CGPoint(x: x, y: y), pinch: pinch, webView: eye.webView)
    }

    private func applyHeadPose(_ pose: HeadPose) {
        let yaw = clamp(pose.yaw * 4.4, -0.38, 0.38)
        let pitch = clamp(pose.pitch * 3.7, -0.26, 0.26)
        let roll = clamp(-pose.roll, -0.16, 0.16)
        let dx = -CGFloat(yaw) * 155
        let dy = CGFloat(pitch) * 105
        eyeLeft.setHeadOffset(dx: dx - 2, dy: dy, roll: roll)
        eyeRight.setHeadOffset(dx: dx + 2, dy: dy, roll: roll)
    }

    private func loadAddress() {
        let raw = addressField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return }
        let normalized = (raw.hasPrefix("http://") || raw.hasPrefix("https://")) ? raw : "https://\(raw)"
        guard let url = URL(string: normalized) else {
            showCameraAlert("Некорректный адрес.")
            return
        }
        eyeLeft.load(url: url)
        eyeRight.load(url: url)
        addressField.resignFirstResponder()
    }

    private func showCameraAlert(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "HandAR Vision", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func clamp(_ value: Double, _ min: Double, _ max: Double) -> Double {
        Swift.min(Swift.max(value, min), max)
    }
}

extension MainViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        loadAddress()
        return true
    }
}

extension MainViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let other = webView === eyeLeft.webView ? eyeRight.webView : eyeLeft.webView
        if other.url?.absoluteString != url.absoluteString {
            other.load(URLRequest(url: url))
        }
        addressField.text = url.absoluteString
        installPageHooksIfNeeded(webView)
        DispatchQueue.main.async { [weak self] in
            self?.hud.setStatus("КАМЕРА • OK   •   BROWSER • OK")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        installPageHooksIfNeeded(webView)
        hud.setStatus("BROWSER • ОШИБКА СЕТИ")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    private func installPageHooksIfNeeded(_ webView: WKWebView) {
        // WebInput.js is installed at document start by EyeContainer. This extra call
        // is intentionally empty; it keeps the navigation lifecycle simple on iOS.
    }
}

struct HeadPose {
    let yaw: Double
    let pitch: Double
    let roll: Double
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

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "handar.camera", qos: .userInitiated)
    private var configured = false
    private var startRequested = false
    private var videoOutput: AVCaptureVideoDataOutput?

    var onFrame: ((CMSampleBuffer, CGImagePropertyOrientation) -> Void)?
    var onStatus: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?
    var onConfigurationFailed: ((String) -> Void)?

    func prepareAndStart() {
        startRequested = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureThenStart()
        case .notDetermined:
            DispatchQueue.main.async { [weak self] in self?.onStatus?("КАМЕРА • РАЗРЕШЕНИЕ...") }
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self else { return }
                if allowed {
                    self.configureThenStart()
                } else {
                    DispatchQueue.main.async { self.onPermissionDenied?() }
                }
            }
        case .denied, .restricted:
            onPermissionDenied?()
        @unknown default:
            onPermissionDenied?()
        }
    }

    func requestStartAgain() {
        startRequested = true
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            prepareAndStart()
            return
        }
        configureThenStart()
    }

    private func configureThenStart() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configure()
            }
            guard self.configured, self.startRequested, !self.session.isRunning else { return }
            DispatchQueue.main.async { self.onStatus?("КАМЕРА • СТАРТ...") }
            self.session.startRunning()
            DispatchQueue.main.async { self.onStatus?("КАМЕРА • OK") }
        }
    }

    private func configure() {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            DispatchQueue.main.async { [weak self] in
                self?.onConfigurationFailed?("Задняя камера iPhone не найдена.")
            }
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                DispatchQueue.main.async { [weak self] in
                    self?.onConfigurationFailed?("Не удалось подключить камеру к AVCaptureSession.")
                }
                return
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                DispatchQueue.main.async { [weak self] in
                    self?.onConfigurationFailed?("Не удалось подключить видеовыход камеры.")
                }
                return
            }
            session.addOutput(output)
            videoOutput = output

            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
            configured = true
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onConfigurationFailed?("Ошибка настройки камеры: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        startRequested = false
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer, captureOrientation())
    }

    private func captureOrientation() -> CGImagePropertyOrientation {
        DispatchQueue.main.sync {
            let orientation = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.interfaceOrientation ?? .landscapeRight
            return orientation == .landscapeLeft ? .left : .right
        }
    }
}

final class MotionTracker {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInteractive
        return q
    }()
    private var reference: CMAttitude?
    private let lock = NSLock()
    var onUpdate: ((HeadPose) -> Void)?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 90.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.lock.lock()
            let ref = self.reference
            self.lock.unlock()
            guard let ref else { return }
            let relative = (motion.attitude.copy() as? CMAttitude) ?? motion.attitude
            relative.multiply(byInverseOf: ref)
            self.onUpdate?(HeadPose(yaw: relative.yaw, pitch: relative.pitch, roll: relative.roll))
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
    private let queue = DispatchQueue(label: "handar.vision", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    private var lastLeft: CGPoint?
    private var lastRight: CGPoint?
    var onUpdate: ((HandSample?, HandSample?) -> Void)?

    func process(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard gate.wait(timeout: .now()) == .success else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.gate.signal() }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([self.request])
                var left: HandSample?
                var right: HandSample?
                for observation in self.request.results ?? [] {
                    guard let index = try? observation.recognizedPoint(.indexTip),
                          let thumb = try? observation.recognizedPoint(.thumbTip),
                          index.confidence > 0.35,
                          thumb.confidence > 0.35 else { continue }

                    let filtered: CGPoint
                    if observation.chirality == .left {
                        filtered = smooth(self.lastLeft, index.location, alpha: 0.45)
                        self.lastLeft = filtered
                    } else {
                        filtered = smooth(self.lastRight, index.location, alpha: 0.45)
                        self.lastRight = filtered
                    }
                    let pinch = hypot(filtered.x - thumb.location.x, filtered.y - thumb.location.y) < 0.055
                    let sample = HandSample(indexTip: filtered, thumbTip: thumb.location, isPinching: pinch)
                    if observation.chirality == .left { left = sample }
                    else { right = sample }
                }
                self.onUpdate?(left, right)
            } catch {
                self.onUpdate?(nil, nil)
            }
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
                let amount = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), deltaY * 2.6)
                let script = "window.scrollBy(0, \(amount));"
                dispatch(script, to: webView)
            }
            dispatch("window.__handarPointerMove(\(point.x),\(point.y),\(pointerID));", to: webView)
        } else if !pinch && state.down {
            state.down = false
            dispatch("window.__handarPointerUp(\(point.x),\(point.y),\(pointerID));", to: webView)
            mirror.filter { $0 !== webView }.forEach { dispatch("window.scrollTo(0, window.scrollY);", to: $0) }
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
    let webView: WKWebView
    private let panelBackground = UIView()
    private let chrome = UIView()
    private let titleLabel = UILabel()
    private var baseTransform: CGAffineTransform = .identity
    private(set) var browserFrame: CGRect = .zero

    init(title: String) {
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

        panelBackground.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        panelBackground.layer.cornerRadius = 18
        panelBackground.layer.borderWidth = 1
        panelBackground.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        addSubview(panelBackground)
        addSubview(webView)
        chrome.backgroundColor = UIColor.black.withAlphaComponent(0.70)
        chrome.layer.cornerRadius = 10
        addSubview(chrome)

        titleLabel.text = "  \(title) • BROWSER"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        chrome.addSubview(titleLabel)

        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear
        webView.alpha = 0.93
        let s = webView.configuration.preferences
        s.javaScriptEnabled = true
        let ws = webView.scrollView
        ws.alwaysBounceVertical = true
        webView.allowsBackForwardNavigationGestures = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let marginX = bounds.width * 0.09
        let marginTop = bounds.height * 0.15
        let panelH = bounds.height * 0.68
        let panel = CGRect(x: marginX, y: marginTop, width: bounds.width - 2 * marginX, height: panelH)
        browserFrame = panel
        panelBackground.frame = panel
        webView.frame = panel.insetBy(dx: 2, dy: 2)
        chrome.frame = CGRect(x: panel.minX, y: panel.minY - 30, width: panel.width, height: 26)
        titleLabel.frame = chrome.bounds.insetBy(dx: 5, dy: 2)
    }

    func load(url: URL) {
        webView.load(URLRequest(url: url))
    }

    func setHeadOffset(dx: CGFloat, dy: CGFloat, roll: CGFloat) {
        let transform = CGAffineTransform(translationX: dx, y: dy).rotated(by: roll)
        self.transform = baseTransform.concatenating(transform)
    }
}

final class CursorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemYellow.withAlphaComponent(0.16)
        layer.borderWidth = 2
        layer.borderColor = UIColor.systemYellow.cgColor
        layer.cornerRadius = 17
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPressed(_ pressed: Bool) {
        alpha = pressed ? 1.0 : 0.75
        transform = pressed ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
    }
}

final class HUDView: UIView {
    let statusText = UILabel()
    var onCenter: (() -> Void)?
    var onBrowser: (() -> Void)?
    var onCamera: (() -> Void)?
    private let center = UIButton(type: .system)
    private let browser = UIButton(type: .system)
    private let camera = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.62)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        statusText.textColor = .white
        statusText.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        statusText.text = "КАМЕРА • ЗАПУСК..."
        addSubview(statusText)

        center.setTitle("CENTER", for: .normal)
        browser.setTitle("BROWSER", for: .normal)
        camera.setTitle("CAM", for: .normal)
        [center, browser, camera].forEach {
            $0.tintColor = .white
            $0.titleLabel?.font = .systemFont(ofSize: 10, weight: .semibold)
            addSubview($0)
        }
        center.addAction(UIAction { [weak self] _ in self?.onCenter?() }, for: .touchUpInside)
        browser.addAction(UIAction { [weak self] _ in self?.onBrowser?() }, for: .touchUpInside)
        camera.addAction(UIAction { [weak self] _ in self?.onCamera?() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        let buttonW: CGFloat = 70
        statusText.frame = CGRect(x: 10, y: 0, width: max(80, bounds.width - buttonW * 3 - 12), height: bounds.height)
        center.frame = CGRect(x: bounds.width - buttonW * 3, y: 0, width: buttonW, height: bounds.height)
        browser.frame = CGRect(x: bounds.width - buttonW * 2, y: 0, width: buttonW, height: bounds.height)
        camera.frame = CGRect(x: bounds.width - buttonW, y: 0, width: buttonW, height: bounds.height)
    }

    func setStatus(_ text: String) { statusText.text = text }
    func setBrowserVisible(_ visible: Bool) { browser.setTitle(visible ? "BROWSER" : "OFF", for: .normal) }
}

private extension UIView {
    func bringSubviewToFront(in root: UIView) {
        root.bringSubviewToFront(self)
    }
}
