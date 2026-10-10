import ARKit
import AVFoundation
import MetalKit
import SceneKit
import simd
import UIKit
import Vision
import WebKit

// MARK: - Надпись в картинку (кириллица + эмодзи)

fileprivate func renderLabelImage(
    _ value: String,
    color: UIColor,
    fontSize: CGFloat,
    weight: UIFont.Weight = .semibold
) -> UIImage? {
    guard !value.isEmpty else { return nil }
    let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]
    let string = NSAttributedString(string: value, attributes: attributes)
    let bounds = string.boundingRect(
        with: CGSize(width: 4000, height: 4000),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
    )
    let size = CGSize(width: ceil(bounds.width) + 2, height: ceil(bounds.height) + 2)
    guard size.width > 2, size.height > 2 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in
        string.draw(
            with: CGRect(x: 1, y: 1, width: bounds.width, height: bounds.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }
}

fileprivate extension SCNMaterial {
    /// Ровный цвет без освещения — сцена светится сама.
    func flat(_ color: UIColor) {
        lightingModel = .constant
        diffuse.contents = color
    }
}

/// Пересечение луча со сферой.
fileprivate func sphereHit(ray: WorldRay, center: SIMD3<Float>, radius: Float) -> Bool {
    let oc = ray.origin - center
    let a = simd_dot(ray.direction, ray.direction)
    let b = 2 * simd_dot(oc, ray.direction)
    let c = simd_dot(oc, oc) - radius * radius
    let discriminant = b * b - 4 * a * c
    guard discriminant >= 0 else { return false }
    let t = (-b - discriminant.squareRoot()) / (2 * a)
    return t > 0
}

/// Плоская надпись, всегда повёрнута к зрителю.
final class LabelPlane: SCNNode {
    private let plane = SCNPlane(width: 1, height: 1)

    init(text: String, color: UIColor = .white, fontSize: CGFloat = 52, weight: UIFont.Weight = .semibold) {
        super.init()
        constraints = [SCNBillboardConstraint()]
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.clear
        plane.materials = [material]
        addChildNode(SCNNode(geometry: plane))
        setText(text, color: color, fontSize: fontSize, weight: weight)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var lastText = " "
    private var lastFontSize: CGFloat = 52
    private var lastWeight: UIFont.Weight = .semibold

    private var planeNodeMaterial: SCNMaterial {
        plane.materials?.first ?? SCNMaterial()
    }

    func setText(
        _ value: String,
        color: UIColor = .white,
        fontSize: CGFloat = 52,
        weight: UIFont.Weight = .semibold
    ) {
        lastText = value
        lastFontSize = fontSize
        lastWeight = weight
        if let image = renderLabelImage(value, color: color, fontSize: fontSize, weight: weight) {
            plane.width = image.size.width
            plane.height = image.size.height
            planeNodeMaterial.diffuse.contents = image
            isHidden = false
        } else {
            isHidden = true
        }
    }

    /// Меняет цвет надписи, не меняя текст.
    func setColor(_ color: UIColor) {
        if let image = renderLabelImage(lastText, color: color, fontSize: lastFontSize, weight: lastWeight) {
            plane.width = image.size.width
            plane.height = image.size.height
            planeNodeMaterial.diffuse.contents = image
            isHidden = false
        } else {
            isHidden = true
        }
    }

    /// Масштаб так, чтобы надпись была `width` метров шириной.
    func fitWidth(_ width: Float) {
        guard plane.width > 1 else { return }
        let s = width / Float(plane.width)
        scale = SCNVector3(s, s, s)
    }
}

// MARK: - Кнопка пульта -------------------------------------------------------

final class CinemaButton {
    let node = SCNNode()
    let title: String
    let hitRadius: Float
    private let plate: SCNNode
    private let base: UIColor
    private let buttonWidth: Float
    private let buttonHeight: Float
    var onTap: (() -> Void)?

    init(title: String, color: UIColor, hitRadius: Float = 0.26,
         width: Float = 0.46, height: Float = 0.24) {
        self.title = title
        self.base = color
        self.hitRadius = hitRadius
        self.buttonWidth = width
        self.buttonHeight = height

        let box = SCNBox(width: CGFloat(width), height: CGFloat(height), length: 0.02, chamferRadius: 0.028)
        let material = SCNMaterial()
        material.flat(color.withAlphaComponent(0.95))
        box.materials = [material]
        plate = SCNNode(geometry: box)
        node.addChildNode(plate)

        if let image = renderLabelImage(title, color: .white, fontSize: 60, weight: .bold) {
            let labelPlane = SCNPlane(width: image.size.width, height: image.size.height)
            let textMaterial = SCNMaterial()
            textMaterial.lightingModel = .constant
            textMaterial.isDoubleSided = true
            textMaterial.diffuse.contents = image
            labelPlane.materials = [textMaterial]
            let textNode = SCNNode(geometry: labelPlane)
            let fit = Float(min(
                CGFloat(width) * 0.90 / Double(image.size.width),
                CGFloat(height) * 0.66 / Double(image.size.height)
            ))
            textNode.scale = SCNVector3(fit, fit, fit)
            textNode.position = SCNVector3(0, 0, 0.014)
            plate.addChildNode(textNode)
        }
        node.constraints = [SCNBillboardConstraint()]
    }

    func hitTest(ray: WorldRay) -> Bool {
        sphereHit(ray: ray, center: node.presentation.simdWorldPosition, radius: hitRadius)
    }

    /// Меняет подпись (например, «⏸ ПАУЗА» ↔ «▶ ИГРАТЬ»).
    func updateLabel(_ value: String) {
        plate.childNodes.forEach { $0.removeFromParent() }
        if let image = renderLabelImage(value, color: .white, fontSize: 60, weight: .bold) {
            let labelPlane = SCNPlane(width: image.size.width, height: image.size.height)
            let textMaterial = SCNMaterial()
            textMaterial.lightingModel = .constant
            textMaterial.isDoubleSided = true
            textMaterial.diffuse.contents = image
            labelPlane.materials = [textMaterial]
            let textNode = SCNNode(geometry: labelPlane)
            let fit = Float(min(
                CGFloat(buttonWidth) * 0.90 / Double(image.size.width),
                CGFloat(buttonHeight) * 0.66 / Double(image.size.height)
            ))
            textNode.scale = SCNVector3(fit, fit, fit)
            textNode.position = SCNVector3(0, 0, 0.014)
            plate.addChildNode(textNode)
        }
    }

    func setHighlight(_ on: Bool) {
        let material = plate.geometry?.firstMaterial
        material?.diffuse.contents = on
            ? UIColor.white.withAlphaComponent(0.95)
            : base.withAlphaComponent(0.95)
    }
}

// MARK: - Моя кисть ----------------------------------------------------------

final class MyHand {
    let node = SCNNode()
    private var fingers: [SCNNode] = []

    init() {
        let skin = SCNMaterial()
        skin.flat(UIColor(red: 0.82, green: 0.62, blue: 0.45, alpha: 1))

        let palm = SCNBox(width: 0.15, height: 0.07, length: 0.05, chamferRadius: 0.022)
        palm.materials = [skin]
        node.addChildNode(SCNNode(geometry: palm))

        let xs: [Float] = [-0.054, -0.018, 0.018, 0.054]
        for (index, x) in xs.enumerated() {
            let length: Float = index == 1 ? 0.088 : 0.076
            let box = SCNBox(width: 0.026, height: CGFloat(length), length: 0.026, chamferRadius: 0.011)
            box.materials = [skin]
            let pivot = SCNNode()
            pivot.position = SCNVector3(x, 0.04, 0)
            let finger = SCNNode(geometry: box)
            finger.position = SCNVector3(0, length * 0.5, 0)
            pivot.addChildNode(finger)
            node.addChildNode(pivot)
            fingers.append(pivot)
        }

        let thumb = SCNBox(width: 0.030, height: 0.080, length: 0.032, chamferRadius: 0.012)
        thumb.materials = [skin]
        let thumbNode = SCNNode(geometry: thumb)
        thumbNode.position = SCNVector3(-0.086, 0.006, 0.012)
        thumbNode.eulerAngles = SCNVector3(0, 0, -0.8)
        node.addChildNode(thumbNode)
    }

    func update(target: SIMD3<Float>, direction: SIMD3<Float>, gripping: Bool) {
        node.simdPosition = target
        node.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: simd_normalize(direction)
        )
        for finger in fingers {
            finger.eulerAngles.x = gripping ? -1.1 : 0
            finger.scale = SCNVector3(1, gripping ? 0.55 : 1, 1)
        }
    }
}

// MARK: - Кинотеатр ----------------------------------------------------------

final class CinemaViewController: UIViewController, MTKViewDelegate, WKNavigationDelegate {
    // Профиль линз шлема
    private var profile = VRProfile.makeDefault()

    // Metal и сцена
    private var metalDevice: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var compositor: VRCompositor?
    private let scene = SCNScene()
    private let headNode = SCNNode()
    private let leftCameraNode = SCNNode()
    private let rightCameraNode = SCNNode()
    private var leftRenderer: SCNRenderer!
    private var rightRenderer: SCNRenderer!
    private var vrView: MTKView!
    private var eyeTexture: MTLTexture?
    private var eyeDepthTexture: MTLTexture?
    private var eyeTextureSize: CGSize = .zero

    // Трекинг рук и головы
    private var tracking: ARStereoTrackingManager!
    private var handTracker: HandTracker!
    private var activeSample: HandSample?
    private var sessionStarted = false

    // Офскрин-плеер: звук наружу, кадр — на виртуальный экран
    private var webView: WKWebView!
    private var snapshotTimer: Timer?
    private var playerReady = false

    // Зал
    private let hallRoot = SCNNode()
    private let screenGroup = SCNNode()
    private var screenColumns: [SCNNode] = []
    private var screenArcZ: [Float] = []
    private var screenMaterial: SCNMaterial!
    private var lampMaterial: SCNMaterial!
    private var roomMaterials: [SCNMaterial] = []
    private var neonMaterials: [SCNMaterial] = []
    private var consoleButtons: [CinemaButton] = []
    private var playButton: CinemaButton?
    private let hallToast = LabelPlane(text: "", fontSize: 44)
    private let myHand = MyHand()
    private var hallAnchored = false

    // Состояние
    private var inCinema = false
    private var lightsOn = true
    private var screenDistance: Float = 4.4
    private var isPlaying = false
    private var playbackTime: Double = 0
    private var volume: Float = 1.0
    private var lastFrameTime = CACurrentMediaTime()
    private var previousPinch = false
    private var toastTask: DispatchWorkItem?

    // 2D-интерфейс телефона
    private var linkScreen: UIScrollView!
    private var linkField: UITextField!
    private var statusLabel: UILabel!
    private var enterButton: UIButton!
    private var settingsPanel: UIScrollView!
    private var ipdSlider: UISlider!
    private var distanceSlider: UISlider!
    private var lightsSwitch: UISwitch!

    // MARK: - Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1)
        profile = VRProfile.load()
        profile.passthrough = false

        setupMetal()
        setupTracking()
        setupWebPlayer()
        build2DUI()
        setupVRView()
        buildHall()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        tracking.setInterfaceOrientation(currentInterfaceOrientation())
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }

    // MARK: - Metal, сцена, камеры

    private func setupMetal() {
        metalDevice = MTLCreateSystemDefaultDevice()
        commandQueue = metalDevice.makeCommandQueue()
        compositor = VRCompositor(device: metalDevice)

        scene.background.contents = UIColor.clear

        let leftCamera = SCNCamera()
        leftCamera.zNear = 0.02
        leftCamera.zFar = 120
        leftCameraNode.camera = leftCamera

        let rightCamera = SCNCamera()
        rightCamera.zNear = 0.02
        rightCamera.zFar = 120
        rightCameraNode.camera = rightCamera

        headNode.addChildNode(leftCameraNode)
        headNode.addChildNode(rightCameraNode)
        scene.rootNode.addChildNode(headNode)

        leftRenderer = SCNRenderer(device: metalDevice, options: nil)
        rightRenderer = SCNRenderer(device: metalDevice, options: nil)
        for renderer in [leftRenderer, rightRenderer] {
            renderer?.scene = scene
            renderer?.autoenablesDefaultLighting = false
            renderer?.isJitteringEnabled = false
        }
        applyEyeGeometry()
    }

    private func applyEyeGeometry() {
        let halfIPD = profile.ipdMM * 0.0005
        leftCameraNode.simdPosition = SIMD3<Float>(-halfIPD, 0, 0)
        rightCameraNode.simdPosition = SIMD3<Float>(halfIPD, 0, 0)
        let left = VRLensMath.frustum(eye: 0, profile: profile)
        let right = VRLensMath.frustum(eye: 1, profile: profile)
        leftCameraNode.camera?.projectionTransform = VRLensMath.projection(left, near: 0.02, far: 120)
        rightCameraNode.camera?.projectionTransform = VRLensMath.projection(right, near: 0.02, far: 120)
    }

    private func setupVRView() {
        vrView = MTKView(frame: view.bounds, device: metalDevice)
        vrView.colorPixelFormat = .bgra8Unorm
        vrView.depthStencilPixelFormat = .invalid
        vrView.framebufferOnly = true
        vrView.preferredFramesPerSecond = 60
        vrView.enableSetNeedsDisplay = false
        vrView.autoResizeDrawable = true
        vrView.isPaused = false
        vrView.isOpaque = true
        vrView.backgroundColor = .black
        vrView.delegate = self
        vrView.isHidden = true
        view.addSubview(vrView)
    }

    // MARK: - Трекинг

    private func setupTracking() {
        handTracker = HandTracker()
        handTracker.onUpdate = { [weak self] left, right in
            let sample = left ?? right
            DispatchQueue.main.async { self?.activeSample = sample }
        }

        tracking = ARStereoTrackingManager()
        tracking.setInterfaceOrientation(currentInterfaceOrientation())
        tracking.onFrame = { [weak self] buffer, orientation in
            self?.handTracker.process(pixelBuffer: buffer, orientation: orientation)
        }
        tracking.onCamera = { [weak self] frame in
            guard let self else { return }
            DispatchQueue.main.async {
                self.headNode.simdTransform = self.tracking.headTransform(frame)
            }
        }
    }

    private func ensureSession() {
        guard !sessionStarted else { return }
        sessionStarted = true
        tracking.start()
    }

    // MARK: - Веб-плеер

    private func setupWebPlayer() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionPlayback = []

        webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.isUserInteractionEnabled = false
        view.addSubview(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        playerReady = true
    }

    /// Разбор ссылки: YouTube → embed-плеер, прямой файл → <video>, иначе как есть.
    private func loadLink(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        playerReady = false
        isPlaying = false
        playbackTime = 0

        if let id = youTubeID(from: text) {
            let embed = embedURL(forID: id)
            webView.loadHTMLString(
                wrapperHTML(playerURL: embed, isIframe: true),
                baseURL: URL(string: "https://www.youtube.com")
            )
            statusLabel.text = "▶️ YouTube подключён — добро пожаловать в зал"
            return
        }

        let lower = text.lowercased()
        if lower.hasSuffix(".mp4") || lower.hasSuffix(".webm") || lower.hasSuffix(".m3u8")
            || lower.hasSuffix(".mov") {
            webView.loadHTMLString(
                wrapperHTML(playerURL: text, isIframe: false),
                baseURL: nil
            )
            statusLabel.text = "▶️ Видеофайл подключён"
            return
        }

        webView.load(URLRequest(url: URL(string: text) ?? URL(string: "about:blank")!))
        statusLabel.text = "🌐 Открываю страницу"
    }

    private func youTubeID(from text: String) -> String? {
        guard let url = URL(string: text) else { return nil }
        let host = (url.host ?? "").lowercased()
        guard host.contains("youtu") else { return nil }
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.count >= 6 ? id : nil
        }
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            return value
        }
        if text.contains("/shorts/") || text.contains("/embed/") || text.contains("/live/") {
            let id = url.lastPathComponent
            return id.count >= 6 ? id : nil
        }
        return nil
    }

    private func embedURL(forID id: String) -> String {
        "https://www.youtube.com/embed/\(id)"
            + "?autoplay=1&playsinline=1&enablejsapi=1&rel=0"
            + "&modestbranding=1&iv_load_policy=3&fs=0&mute=0"
    }

    private func wrapperHTML(playerURL: String, isIframe: Bool) -> String {
        let script = """
        function __cmd(cmd, arg) {
          try {
            var f = document.getElementById('player');
            if (f && f.tagName === 'IFRAME' && f.contentWindow) {
              var payload = {event: 'command', func: cmd, args: ''};
              if (cmd === 'setVolume') payload.args = [parseInt(arg || '100', 10)];
              if (cmd === 'seekTo') payload.args = [parseFloat(arg || '0'), true];
              f.contentWindow.postMessage(JSON.stringify(payload), '*');
            } else {
              var v = document.querySelector('video');
              if (!v) return;
              if (cmd === 'playVideo') { v.play(); }
              else if (cmd === 'pauseVideo') { v.pause(); }
              else if (cmd === 'setVolume') { v.volume = Math.max(0, Math.min(1, parseFloat(arg || '100') / 100)); }
              else if (cmd === 'seekTo') { v.currentTime = Math.max(0, parseFloat(arg || '0')); }
            }
          } catch (e) {}
        }
        """
        if isIframe {
            return """
            <!doctype html><html><head>
            <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
            <style>html,body{margin:0;padding:0;background:#000;overflow:hidden;width:100%;height:100%}
            iframe{border:0;position:absolute;left:0;top:0;width:100%;height:100%}</style></head>
            <body><iframe id="player" src="\(playerURL)"
              allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
            <script>\(script)</script></body></html>
            """
        }
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;padding:0;background:#000;overflow:hidden;width:100%;height:100%}
        video{position:absolute;left:0;top:0;width:100%;height:100%;background:#000}</style></head>
        <body><video id="player" src="\(playerURL)" autoplay playsinline></video>
        <script>\(script)</script></body></html>
        """
    }

    private func runCommand(_ command: String, argument: String = "") {
        let js = "__cmd('\(command)', '\(argument)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Кадры на экран зала

    private func startSnapshots() {
        snapshotTimer?.invalidate()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            self?.grabFrame()
        }
    }

    private func grabFrame() {
        guard playerReady else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: 1280)
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, let image else { return }
            DispatchQueue.main.async {
                self.screenMaterial.diffuse.contents = image
                self.screenMaterial.emission.contents = image
            }
        }
    }

    // MARK: - 2D-интерфейс телефона

    private func build2DUI() {
        linkScreen = UIScrollView(frame: view.bounds)
        linkScreen.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1)
        linkScreen.alwaysBounceVertical = true
        view.addSubview(linkScreen)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        linkScreen.addSubview(stack)

        let title = bigLabel("🎬 Домашний Кинотеатр", size: 30, color: UIColor(red: 0.45, green: 0.85, blue: 1, alpha: 1))
        let subtitle = bigLabel(
            "Вставь ссылку на YouTube (или .mp4) — фильм сразу пойдёт на огромный экран зала.",
            size: 16,
            color: UIColor(white: 0.75, alpha: 1)
        )
        subtitle.numberOfLines = 0

        let fieldRow = UIStackView()
        fieldRow.axis = .horizontal
        fieldRow.spacing = 10
        fieldRow.distribution = .fill

        linkField = UITextField()
        linkField.placeholder = "https://youtube.com/watch?v=..."
        linkField.borderStyle = .roundedRect
        linkField.backgroundColor = UIColor(white: 0.10, alpha: 1)
        linkField.textColor = .white
        linkField.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        linkField.autocapitalizationType = .none
        linkField.autocorrectionType = .no
        linkField.keyboardType = .URL
        linkField.returnKeyType = .done
        linkField.clearButtonMode = .whileEditing
        fieldRow.addArrangedSubview(linkField)

        let pasteButton = chromeButton("📋 Вставить", wide: false)
        pasteButton.addTarget(self, action: #selector(tapPaste), for: .touchUpInside)
        fieldRow.addArrangedSubview(pasteButton)
        linkField.widthAnchor.constraint(equalTo: fieldRow.widthAnchor, multiplier: 0.72).isActive = true

        enterButton = chromeButton("▶ В ЗАЛ", wide: true, accent: true)
        enterButton.addTarget(self, action: #selector(tapEnter), for: .touchUpInside)

        statusLabel = bigLabel("", size: 15, color: UIColor(red: 0.55, green: 0.95, blue: 0.65, alpha: 1))
        statusLabel.numberOfLines = 0

        let settingsButton = chromeButton("🎚 Настройки шлема", wide: true)
        settingsButton.addTarget(self, action: #selector(tapOpenSettings), for: .touchUpInside)

        let howTo = bigLabel(
            """
            🕹 Как смотреть:
            1. Вставь ссылку и нажми «В ЗАЛ».
            2. Поверни голову — экран впереди, кресла за спиной.
            3. Пульт сзади: 💡 свет, ⏪⏩ экран ближе/дальше,
               ⏸ пауза, 🔊 громкость, ⏪⏩ ±10 секунд, 🔁 сначала.
            4. 🔗 Ссылка — вернуться сюда и вставить другую.
            5. 🚪 Выход — выйти из зала.
            """,
            size: 14,
            color: UIColor(white: 0.60, alpha: 1)
        )
        howTo.numberOfLines = 0

        for view in [title, subtitle, fieldRow, enterButton, statusLabel, settingsButton, howTo] as [UIView] {
            stack.addArrangedSubview(view)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: linkScreen.topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: linkScreen.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: linkScreen.trailingAnchor, constant: -40),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: linkScreen.bottomAnchor, constant: -40),
            stack.widthAnchor.constraint(equalTo: linkScreen.widthAnchor, multiplier: 0.62)
        ])

        // Панель настроек
        settingsPanel = UIScrollView(frame: view.bounds)
        settingsPanel.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1)
        settingsPanel.isHidden = true
        view.addSubview(settingsPanel)

        let settingsStack = UIStackView()
        settingsStack.axis = .vertical
        settingsStack.spacing = 18
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        settingsPanel.addSubview(settingsStack)

        let settingsTitle = bigLabel("🎚 Настройки шлема", size: 26,
                                     color: UIColor(red: 0.45, green: 0.85, blue: 1, alpha: 1))
        settingsStack.addArrangedSubview(settingsTitle)

        ipdSlider = UISlider()
        ipdSlider.minimumValue = 52
        ipdSlider.maximumValue = 76
        ipdSlider.value = profile.ipdMM
        ipdSlider.addTarget(self, action: #selector(ipdChanged), for: .valueChanged)
        settingsStack.addArrangedSubview(row("Межзрачковое расстояние", control: ipdSlider, value: ipdSlider.value))

        distanceSlider = UISlider()
        distanceSlider.minimumValue = 2.4
        distanceSlider.maximumValue = 9.0
        distanceSlider.value = screenDistance
        distanceSlider.addTarget(self, action: #selector(distanceChanged), for: .valueChanged)
        settingsStack.addArrangedSubview(row("Дистанция до экрана", control: distanceSlider, value: distanceSlider.value))

        lightsSwitch = UISwitch()
        lightsSwitch.isOn = lightsOn
        lightsSwitch.addTarget(self, action: #selector(lightsChanged), for: .valueChanged)
        let lightsRow = UIStackView(arrangedSubviews: [
            bigLabel("💡 Свет в зале", size: 17, color: .white), UIView(), lightsSwitch
        ])
        lightsRow.axis = .horizontal
        lightsRow.spacing = 12
        settingsStack.addArrangedSubview(lightsRow)

        let backButton = chromeButton("↩️ Назад к ссылке", wide: true)
        backButton.addTarget(self, action: #selector(tapBackFromSettings), for: .touchUpInside)
        settingsStack.addArrangedSubview(backButton)

        NSLayoutConstraint.activate([
            settingsStack.topAnchor.constraint(equalTo: settingsPanel.topAnchor, constant: 60),
            settingsStack.leadingAnchor.constraint(equalTo: settingsPanel.leadingAnchor, constant: 60),
            settingsStack.trailingAnchor.constraint(equalTo: settingsPanel.trailingAnchor, constant: -60),
            settingsStack.widthAnchor.constraint(equalTo: settingsPanel.widthAnchor, multiplier: 0.55)
        ])
    }

    private func bigLabel(_ text: String, size: CGFloat, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: size, weight: .semibold)
        label.textColor = color
        label.numberOfLines = 1
        return label
    }

    private func chromeButton(_ title: String, wide: Bool, accent: Bool = false) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        configuration.baseBackgroundColor = accent
            ? UIColor(red: 0.85, green: 0.18, blue: 0.30, alpha: 1)
            : UIColor(white: 0.13, alpha: 1)
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        button.layer.cornerRadius = 14
        if wide {
            button.heightAnchor.constraint(equalToConstant: 54).isActive = true
        }
        return button
    }

    private func row(_ title: String, control: UISlider, value: Float) -> UIStackView {
        let label = bigLabel("\(title): \(Int(value))", size: 16, color: .white)
        label.tag = 900
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    // MARK: - Зал

    private func buildHall() {
        // Материалы помещения
        let floorMat = SCNMaterial()
        floorMat.flat(UIColor(white: 0.12, alpha: 1))
        let wallMat = SCNMaterial()
        wallMat.flat(UIColor(white: 0.05, alpha: 1))
        let ceilingMat = SCNMaterial()
        ceilingMat.flat(UIColor(white: 0.10, alpha: 1))
        let seatMat = SCNMaterial()
        seatMat.flat(UIColor(red: 0.45, green: 0.06, blue: 0.10, alpha: 1))
        lampMaterial = SCNMaterial()
        lampMaterial.lightingModel = .constant
        lampMaterial.diffuse.contents = UIColor(white: 0.9, alpha: 1)
        lampMaterial.emission.contents = UIColor.white

        let neonCyan = SCNMaterial()
        neonCyan.lightingModel = .constant
        neonCyan.diffuse.contents = UIColor(red: 0.2, green: 0.9, blue: 1, alpha: 1)
        neonCyan.emission.contents = UIColor(red: 0.2, green: 0.9, blue: 1, alpha: 1)
        let neonMagenta = SCNMaterial()
        neonMagenta.lightingModel = .constant
        neonMagenta.diffuse.contents = UIColor(red: 1, green: 0.25, blue: 0.75, alpha: 1)
        neonMagenta.emission.contents = UIColor(red: 1, green: 0.25, blue: 0.75, alpha: 1)

        roomMaterials = [floorMat, wallMat, ceilingMat, seatMat]
        neonMaterials = [neonCyan, neonMagenta]

        func addBox(
            _ w: CGFloat, _ h: CGFloat, _ d: CGFloat,
            _ material: SCNMaterial,
            _ x: Float, _ y: Float, _ z: Float,
            rotationY: Float = 0
        ) -> SCNNode {
            let geometry = SCNBox(width: w, height: h, length: d, chamferRadius: 0)
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(x, y, z)
            node.eulerAngles.y = rotationY
            hallRoot.addChildNode(node)
            return node
        }

        // Пол, потолок, стены
        addBox(20, 0.2, 26, floorMat, 0, -0.1, 2)
        addBox(20, 0.2, 26, ceilingMat, 0, 3.8, 2)
        addBox(20, 4.0, 0.2, wallMat, 0, 2.0, 13)      // задняя стена
        addBox(20, 4.0, 0.2, wallMat, 0, 2.0, -9)      // за экраном
        addBox(0.2, 4.0, 26, wallMat, -10, 2.0, 2)     // левая
        addBox(0.2, 4.0, 26, wallMat, 10, 2.0, 2)      // правая

        // Неон по бокам
        addBox(0.08, 0.08, 24, neonCyan, -9.8, 1.5, 2)
        addBox(0.08, 0.08, 24, neonMagenta, 9.8, 1.5, 2)

        // Лампы на потолке
        for index in 0..<7 {
            addBox(0.7, 0.05, 0.14, lampMaterial, -4.2 + Float(index) * 1.4, 3.5, -3.2)
            addBox(0.7, 0.05, 0.14, lampMaterial, -4.2 + Float(index) * 1.4, 3.5, 4.5)
        }

        // Экран: изогнутая стена из 15 сегментов
        let radius: Float = 7.0
        let halfAngle: Float = 0.95
        let columns = 15
        let columnWidth = radius * 2 * tan(halfAngle / Float(columns))
        let columnHeight: Float = 3.0
        screenMaterial = SCNMaterial()
        screenMaterial.lightingModel = .constant
        screenMaterial.diffuse.contents = UIColor.black
        screenMaterial.emission.contents = UIColor.black

        screenGroup.position = SCNVector3(0, 0, 0)
        hallRoot.addChildNode(screenGroup)

        let screenGeometry = SCNBox(
            width: CGFloat(columnWidth), height: CGFloat(columnHeight), length: 0.06,
            chamferRadius: 0
        )
        screenGeometry.materials = [screenMaterial]
        for index in 0..<columns {
            let angle = -halfAngle + (Float(index) + 0.5) * (2 * halfAngle / Float(columns))
            let column = SCNNode(geometry: screenGeometry)
            column.position = SCNVector3(radius * sin(angle), 1.62, 0)
            column.eulerAngles.y = -angle
            screenGroup.addChildNode(column)
            screenColumns.append(column)
            screenArcZ.append(radius - radius * cos(angle))
        }
        applyScreenDistance()

        // Свечение за экраном
        let glowMaterial = SCNMaterial()
        glowMaterial.lightingModel = .constant
        glowMaterial.diffuse.contents = UIColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1)
        glowMaterial.emission.contents = UIColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1)
        let glow = SCNPlane(width: 13, height: 4.2)
        glow.materials = [glowMaterial]
        let glowNode = SCNNode(geometry: glow)
        glowNode.position = SCNVector3(0, 1.6, -screenDistance + 0.22)
        screenGroup.addChildNode(glowNode)
        screenGlow = glowNode

        // Подпись под экраном
        screenCaption = LabelPlane(text: "🎬 HandAR IMAX", fontSize: 52, weight: .bold)
        screenCaption.setColor(UIColor(red: 0.45, green: 0.85, blue: 1, alpha: 1))
        screenCaption.position = SCNVector3(0, 0.28, -screenDistance + 0.4)
        screenCaption.fitWidth(2.4)
        screenGroup.addChildNode(screenCaption)

        // Кресла: 6 рядов по 11
        for rowIndex in 0..<6 {
            let z = 1.6 + Float(rowIndex) * 1.05
            for column in 0..<11 {
                let x = -3.3 + Float(column) * 0.66
                addBox(0.52, 0.42, 0.50, seatMat, x, 0.26, z)             // сиденье
                addBox(0.52, 0.58, 0.12, seatMat, x, 0.72, z + 0.26)      // спинка
                addBox(0.10, 0.10, 0.42, seatMat, x - 0.29, 0.48, z)      // подлокотники
                addBox(0.10, 0.10, 0.42, seatMat, x + 0.29, 0.48, z)
            }
        }

        // Пульт за спиной
        let consoleMat = SCNMaterial()
        consoleMat.flat(UIColor(white: 0.16, alpha: 1))
        let consoleTopMat = SCNMaterial()
        consoleTopMat.flat(UIColor(red: 0.12, green: 0.14, blue: 0.20, alpha: 1))
        addBox(2.9, 0.06, 0.8, consoleTopMat, 0, 0.86, 1.9)
        addBox(2.9, 0.86, 0.05, consoleMat, 0, 1.36, 2.16)
        addBox(0.06, 0.86, 0.7, consoleMat, -1.4, 0.43, 1.9)
        addBox(0.06, 0.86, 0.7, consoleMat, 1.4, 0.43, 1.9)

        buildConsoleButtons()

        let consoleTitle = LabelPlane(text: "🎛 ПУЛЬТ — ПОВЕРНИСЬ НАЗАД", fontSize: 52, weight: .bold)
        consoleTitle.setColor(UIColor(red: 0.45, green: 0.85, blue: 1, alpha: 1))
        consoleTitle.position = SCNVector3(0, 1.92, 2.16)
        consoleTitle.fitWidth(2.2)
        hallRoot.addChildNode(consoleTitle)

        hallToast.position = SCNVector3(0, 0.55, 2.4)
        hallToast.fitWidth(2.6)
        hallRoot.addChildNode(hallToast)

        // Моя кисть живёт в мировых координатах
        hallRoot.addChildNode(myHand.node)

        hallRoot.isHidden = true
        scene.rootNode.addChildNode(hallRoot)
        applyLights()
    }

    private var screenGlow = SCNNode()
    private var screenCaption = LabelPlane(text: "", fontSize: 44)

    private func buildConsoleButtons() {
        let columns: [Float] = [-0.81, -0.27, 0.27, 0.81]
        let rows: [Float] = [1.45, 1.22, 0.99]

        func add(_ title: String, column: Int, row: Int, color: UIColor, action: @escaping () -> Void) -> CinemaButton {
            let button = CinemaButton(title: title, color: color, width: 0.46, height: 0.22)
            button.node.position = SCNVector3(columns[column], rows[row], 1.86)
            button.onTap = action
            hallRoot.addChildNode(button.node)
            consoleButtons.append(button)
            return button
        }

        let green = UIColor(red: 0.15, green: 0.70, blue: 0.32, alpha: 1)
        let red = UIColor(red: 0.80, green: 0.16, blue: 0.22, alpha: 1)
        let blue = UIColor(red: 0.12, green: 0.55, blue: 0.95, alpha: 1)
        let amber = UIColor(red: 0.95, green: 0.70, blue: 0.10, alpha: 1)
        let gray = UIColor(white: 0.30, alpha: 1)

        playButton = add("⏸ ПАУЗА", column: 3, row: 0, color: gray) { [weak self] in
            self?.togglePlay()
        }
        add("💡 СВЕТ", column: 0, row: 0, color: amber) { [weak self] in
            self?.toggleLights()
        }
        add("⏪ БЛИЖЕ", column: 1, row: 0, color: blue) { [weak self] in
            self?.moveScreen(-0.3)
        }
        add("⏩ ДАЛЬШЕ", column: 2, row: 0, color: blue) { [weak self] in
            self?.moveScreen(0.3)
        }
        add("🔊 ГРОМЧЕ", column: 0, row: 1, color: gray) { [weak self] in
            self?.changeVolume(0.2)
        }
        add("🔉 ТИШЕ", column: 1, row: 1, color: gray) { [weak self] in
            self?.changeVolume(-0.2)
        }
        add("⏪ −10с", column: 2, row: 1, color: gray) { [weak self] in
            self?.seek(by: -10)
        }
        add("⏩ +10с", column: 3, row: 1, color: gray) { [weak self] in
            self?.seek(by: 10)
        }
        add("🔗 ССЫЛКА", column: 0, row: 2, color: red) { [weak self] in
            self?.openLinkScreen()
        }
        add("🔁 СНАЧАЛА", column: 1, row: 2, color: gray) { [weak self] in
            self?.restart()
        }
        add("🎚 НАСТРОЙКИ", column: 2, row: 2, color: gray) { [weak self] in
            self?.openSettings()
        }
        add("🚪 ВЫХОД", column: 3, row: 2, color: red) { [weak self] in
            self?.exitToPhone()
        }
    }

    // MARK: - Действия пульта

    private func toggleLights() {
        lightsOn.toggle()
        applyLights()
        hallToast(lightsOn ? "💡 Свет включён" : "🌑 Свет выключен — кинотеатр!")
    }

    private func applyLights() {
        let levels: [CGFloat] = lightsOn ? [0.12, 0.30, 0.35, 0.45] : [0.05, 0.045, 0.10, 0.14]
        for (index, material) in roomMaterials.enumerated() {
            material.diffuse.contents = UIColor(white: levels[index], alpha: 1)
        }
        lampMaterial.emission.contents = lightsOn
            ? UIColor(red: 1, green: 0.95, blue: 0.82, alpha: 1)
            : UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        lampMaterial.diffuse.contents = lightsOn ? UIColor.white : UIColor(white: 0.15, alpha: 1)
        let neon: CGFloat = lightsOn ? 1.0 : 0.35
        for material in neonMaterials {
            material.emission.contents = (material.diffuse.contents as? UIColor)?
                .withAlphaComponent(neon) ?? UIColor.white
        }
    }

    private func moveScreen(_ delta: Float) {
        screenDistance = min(max(screenDistance + delta, 2.4), 9.0)
        applyScreenDistance()
        hallToast("📺 Экран на \(String(format: "%.1f", screenDistance)) метрах")
    }

    private func applyScreenDistance() {
        for (index, column) in screenColumns.enumerated() {
            column.position.z = -screenDistance + screenArcZ[index]
        }
        screenGlow.position.z = -screenDistance + 0.22
        screenCaption.position.z = -screenDistance + 0.4
    }

    private func togglePlay() {
        if isPlaying {
            runCommand("pauseVideo")
            isPlaying = false
            playButton?.updateLabel("▶ ИГРАТЬ")
            hallToast("⏸ Пауза")
        } else {
            runCommand("playVideo")
            isPlaying = true
            playButton?.updateLabel("⏸ ПАУЗА")
            hallToast("▶ Продолжаем")
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func changeVolume(_ delta: Float) {
        volume = min(max(volume + delta, 0), 1)
        runCommand("setVolume", argument: "\(Int(volume * 100))")
        hallToast("🔊 Громкость \(Int(volume * 100))%")
    }

    private func seek(by seconds: Double) {
        playbackTime = max(0, playbackTime + seconds)
        runCommand("seekTo", argument: "\(Int(playbackTime))")
        hallToast("⏩ \(seconds > 0 ? "+" : "")\(Int(seconds)) сек")
    }

    private func restart() {
        playbackTime = 0
        runCommand("seekTo", argument: "0")
        runCommand("playVideo")
        isPlaying = true
        playButton?.updateLabel("⏸ ПАУЗА")
        hallToast("🔁 Сначала")
    }

    // MARK: - Переходы между телефоном и залом

    @objc private func tapPaste() {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            linkField.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            statusLabel.text = "📋 Ссылка вставлена. Жми «В ЗАЛ»"
        } else {
            statusLabel.text = "⚠️ В буфере обмена нет ссылки"
        }
    }

    @objc private func tapEnter() {
        let text = (linkField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusLabel.text = "⚠️ Сначала вставь ссылку на видео"
            return
        }
        linkField.resignFirstResponder()
        loadLink(text)
        enterHall()
    }

    private func enterHall() {
        linkScreen.isHidden = true
        settingsPanel.isHidden = true
        vrView.isHidden = false
        view.bringSubviewToFront(vrView)
        ensureSession()
        if !hallAnchored {
            anchorHall()
            hallAnchored = true
        }
        hallRoot.isHidden = false
        inCinema = true
        isPlaying = true
        playButton?.updateLabel("⏸ ПАУЗА")
        startSnapshots()
        hallToast("🎬 Фильм пошёл! Пульт — повернись назад")
    }

    private func anchorHall() {
        let head = headNode.simdWorldPosition
        let forward = simd_normalize(SIMD3<Float>(
            -headNode.simdWorldTransform.columns.2.x,
            0,
            -headNode.simdWorldTransform.columns.2.z
        ))
        hallRoot.simdPosition = simd_float3(head.x, head.y - 1.05, head.z)
        hallRoot.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward)
    }

    private func leaveHall() {
        inCinema = false
        hallRoot.isHidden = true
        vrView.isHidden = true
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    @objc private func tapOpenSettings() {
        linkScreen.isHidden = true
        settingsPanel.isHidden = false
    }

    @objc private func tapBackFromSettings() {
        settingsPanel.isHidden = true
        linkScreen.isHidden = false
    }

    private func openSettings() {
        leaveHall()
        linkScreen.isHidden = true
        settingsPanel.isHidden = false
    }

    private func openLinkScreen() {
        leaveHall()
        settingsPanel.isHidden = true
        linkScreen.isHidden = false
    }

    private func exitToPhone() {
        runCommand("pauseVideo")
        isPlaying = false
        leaveHall()
        statusLabel.text = "🚪 Вышел из зала. Фильм на паузе."
    }

    @objc private func ipdChanged() {
        profile.ipdMM = ipdSlider.value
        applyEyeGeometry()
        profile.save()
        refreshSettingsLabels()
    }

    @objc private func distanceChanged() {
        screenDistance = distanceSlider.value
        applyScreenDistance()
        refreshSettingsLabels()
    }

    @objc private func lightsChanged() {
        lightsOn = lightsSwitch.isOn
        applyLights()
    }

    private func refreshSettingsLabels() {
        for case let stack as UIStackView in settingsPanel.subviews where stack.axis == .vertical {
            for case let row as UIStackView in stack.arrangedSubviews {
                if let label = row.arrangedSubviews.first as? UILabel, label.tag == 900 {
                    if let slider = row.arrangedSubviews.last as? UISlider {
                        let title = slider === ipdSlider ? "Межзрачковое расстояние" : "Дистанция до экрана"
                        label.text = "\(title): \(Int(slider.value))"
                    }
                }
            }
        }
    }

    private func hallToast(_ text: String) {
        hallToast.setText(text)
        toastTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.hallToast.setText("")
        }
        toastTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: task)
    }

    // MARK: - Кадр

    func draw(in view: MTKView) {
        guard inCinema, let compositor else { return }
        guard
            let drawable = view.currentDrawable,
            let passDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
        lastFrameTime = now
        updateGame(dt: dt)

        ensureEyeTextures(for: drawableSize)
        guard let eyeTexture, let eyeDepthTexture else { return }

        let eyeWidth = CGFloat(eyeTexture.width / 2)
        let eyeHeight = CGFloat(eyeTexture.height)
        let time = now

        let leftPass = MTLRenderPassDescriptor()
        leftPass.colorAttachments[0].texture = eyeTexture
        leftPass.colorAttachments[0].loadAction = .clear
        leftPass.colorAttachments[0].storeAction = .store
        leftPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        leftPass.depthAttachment.texture = eyeDepthTexture
        leftPass.depthAttachment.loadAction = .clear
        leftPass.depthAttachment.storeAction = .dontCare
        leftPass.depthAttachment.clearDepth = 1.0

        leftRenderer.pointOfView = leftCameraNode
        leftRenderer.render(
            atTime: time,
            viewport: CGRect(x: 0, y: 0, width: eyeWidth, height: eyeHeight),
            commandBuffer: commandBuffer,
            passDescriptor: leftPass
        )

        let rightPass = MTLRenderPassDescriptor()
        rightPass.colorAttachments[0].texture = eyeTexture
        rightPass.colorAttachments[0].loadAction = .load
        rightPass.colorAttachments[0].storeAction = .store
        rightPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        rightPass.depthAttachment.texture = eyeDepthTexture
        rightPass.depthAttachment.loadAction = .clear
        rightPass.depthAttachment.storeAction = .dontCare
        rightPass.depthAttachment.clearDepth = 1.0

        rightRenderer.pointOfView = rightCameraNode
        rightRenderer.render(
            atTime: time,
            viewport: CGRect(x: eyeWidth, y: 0, width: eyeWidth, height: eyeHeight),
            commandBuffer: commandBuffer,
            passDescriptor: rightPass
        )

        var uniforms = makeUniforms(drawableSize: drawableSize)
        uniforms.passthrough = 0
        uniforms.handMaskEnabled = 0
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            compositor.encode(
                into: encoder,
                eyeTexture: eyeTexture,
                cameraY: nil,
                cameraCbCr: nil,
                handMask: eyeTexture,
                uniforms: uniforms
            )
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func ensureEyeTextures(for drawableSize: CGSize) {
        let factor = CGFloat(max(profile.supersample, 1))
        let target = CGSize(
            width: (drawableSize.width * factor).rounded(),
            height: (drawableSize.height * factor).rounded()
        )
        if eyeTexture != nil, eyeTextureSize == target { return }

        let colorDescriptor = MTLTextureDescriptor.texture2dDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(target.width),
            height: Int(target.height),
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private

        let depthDescriptor = MTLTextureDescriptor.texture2dDescriptor(
            pixelFormat: .depth32Float,
            width: Int(target.width),
            height: Int(target.height),
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private

        eyeTexture = metalDevice.makeTexture(descriptor: colorDescriptor)
        eyeDepthTexture = metalDevice.makeTexture(descriptor: depthDescriptor)
        eyeTextureSize = target
    }

    private func makeUniforms(drawableSize: CGSize) -> VRUniforms {
        var uniforms = VRUniforms()
        uniforms.lensCenterL = VRLensMath.lensCenterUV(eye: 0, profile: profile)
        uniforms.lensCenterR = VRLensMath.lensCenterUV(eye: 1, profile: profile)
        uniforms.aspect = Float((drawableSize.width * 0.5) / max(drawableSize.height, 1))
        uniforms.k1 = profile.k1
        uniforms.k2 = profile.k2
        uniforms.chroma = profile.chroma
        let maxLensRadius = min(Float(0.5), Float(0.5) / max(uniforms.aspect, 0.001))
        _ = maxLensRadius
        uniforms.rClip = 0.497
        uniforms.passthrough = 0
        uniforms.handMaskEnabled = 0
        return uniforms
    }

    // MARK: - Ввод

    private func updateGame(dt: Float) {
        guard let sample = activeSample else { return }
        let ray = tracking.worldRay(visionPoint: sample.indexTip)
        if let ray {
            myHand.update(target: ray.point(at: 0.42), direction: ray.direction, gripping: sample.clickPinch)
        }

        // Подсветка под лучом
        for button in consoleButtons {
            var highlighted = false
            if let ray { highlighted = button.hitTest(ray: ray) }
            button.setHighlight(highlighted)
        }

        if sample.clickPinch && !previousPinch, let ray {
            for button in consoleButtons where button.hitTest(ray: ray) {
                button.onTap?()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                break
            }
        }
        previousPinch = sample.clickPinch

        if isPlaying {
            playbackTime += Double(dt)
        }
    }
}
