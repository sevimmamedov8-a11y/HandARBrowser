import SceneKit
import simd
import UIKit

// MARK: - Вспомогательные вещи (локальные, чтобы не трогать SecurityVRGame)

private extension SCNMaterial {
    /// Неосвещённый ровный цвет — для экрана, кнопок и подписей.
    func cineConstant(_ color: UIColor, emissive: CGFloat = 0) {
        lightingModel = .constant
        diffuse.contents = color
        if emissive > 0 {
            emission.contents = color.withAlphaComponent(emissive)
        } else {
            emission.contents = UIColor.black
        }
    }

    /// Материал, реагирующий на свет зала — для стен, пола и сидений.
    func cineLit(_ color: UIColor, emissive: UIColor = .black) {
        lightingModel = .lambert
        diffuse.contents = color
        emission.contents = emissive
        specular.contents = UIColor.black
    }
}

private func raySphereHit(ray: WorldRay, center: SIMD3<Float>, radius: Float) -> Float? {
    let oc = ray.origin - center
    let a = simd_dot(ray.direction, ray.direction)
    let b = 2 * simd_dot(oc, ray.direction)
    let c = simd_dot(oc, oc) - radius * radius
    let discriminant = b * b - 4 * a * c
    guard discriminant >= 0 else { return nil }
    let t = (-b - discriminant.squareRoot()) / (2 * a)
    return t > 0 ? t : nil
}

private func renderTextImage(
    _ value: String,
    color: UIColor,
    fontSize: CGFloat,
    weight: UIFont.Weight = .semibold
) -> UIImage? {
    guard !value.isEmpty else { return nil }
    let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
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

/// Текстовая плашка, всегда повёрнутая к камере.
private final class CineText: SCNNode {
    private var current = ""
    private let plane = SCNPlane(width: 1, height: 1)
    private let planeNode = SCNNode()

    override init() {
        super.init()
        constraints = [SCNBillboardConstraint()]
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.clear
        plane.materials = [material]
        planeNode.geometry = plane
        addChildNode(planeNode)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ value: String, color: UIColor = .white) {
        guard value != current else { return }
        current = value
        if let image = renderTextImage(value, color: color, fontSize: 64) {
            plane.width = image.size.width
            plane.height = image.size.height
            planeNode.geometry?.firstMaterial?.diffuse.contents = image
            planeNode.isHidden = false
        } else {
            planeNode.isHidden = true
        }
    }

    func fitWidth(_ width: Float) {
        guard plane.width > 1 else { return }
        let scale = width / Float(plane.width)
        self.scale = SCNVector3(scale, scale, scale)
    }
}

/// 3D-кнопка на панели управления.
private final class CineButton {
    let node = SCNNode()
    let hitRadius: Float
    private let plate: SCNNode
    private let textNode = SCNNode()
    private let base: UIColor

    init(title: String, color: UIColor, hitRadius: Float = 0.3) {
        self.base = color
        self.hitRadius = hitRadius

        let box = SCNBox(width: 0.64, height: 0.24, length: 0.03, chamferRadius: 0.03)
        let material = SCNMaterial()
        material.cineConstant(color.withAlphaComponent(0.95), emissive: 0.22)
        box.materials = [material]
        plate = SCNNode(geometry: box)
        node.addChildNode(plate)
        node.addChildNode(textNode)
        node.constraints = [SCNBillboardConstraint()]
        setTitle(title)
    }

    func setTitle(_ title: String) {
        guard let image = renderTextImage(title, color: .white, fontSize: 54, weight: .bold) else {
            textNode.isHidden = true
            return
        }
        let plane = SCNPlane(width: image.size.width, height: image.size.height)
        let material = SCNMaterial()
        material.cineConstant(.white)
        material.diffuse.contents = image
        plane.materials = [material]
        textNode.geometry = plane
        let fit = Float(min(0.56 / Double(image.size.width), 0.17 / Double(image.size.height)))
        textNode.scale = SCNVector3(fit, fit, fit)
        textNode.position = SCNVector3(0, 0, 0.02)
        textNode.isHidden = false
    }

    func hitTest(ray: WorldRay) -> Bool {
        raySphereHit(ray: ray, center: node.presentation.simdWorldPosition, radius: hitRadius) != nil
    }

    func setHighlight(_ highlighted: Bool) {
        let material = plate.geometry?.firstMaterial
        material?.diffuse.contents = highlighted
            ? UIColor.white.withAlphaComponent(0.95)
            : base.withAlphaComponent(0.95)
        material?.emission.contents = highlighted
            ? base.withAlphaComponent(0.9)
            : base.withAlphaComponent(0.22)
    }
}

// MARK: - Кинотеатр

/// Полноценный 3D-кинозал: экран спереди, ряды кресел с подлокотниками,
/// потолочный свет и панель управления за спиной зрителя.
final class CinemaHall {

    /// Размер экрана (совпадает с «кинорежимом» браузера, чтобы видео
    /// аккуратно легло в ту же плоскость).
    static let screenWidth: Float = 3.15
    static let screenHeight: Float = 1.77
    static let screenDistance: Float = 3.4

    var onExitRequested: (() -> Void)?
    var onToggleLights: ((Bool) -> Void)?
    var onPlayPause: (() -> Void)?
    var onVolume: ((Float) -> Void)?

    private(set) var isRunning = false
    private(set) var lightsOn = true
    /// Мировая позиция и ориентация экрана — сюда MainViewController ставит
    /// браузерную панель.
    private(set) var screenWorldTransform = matrix_identity_float4x4

    private weak var scene: SCNScene?
    private let root = SCNNode()
    private let ambientLight = SCNLight()

    private var ceilingStrips: [SCNNode] = []

    private let lightButton = CineButton(title: "💡 СВЕТ", color: UIColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 1))
    private let playButton = CineButton(title: "▶ ИГРАТЬ", color: UIColor(red: 0.15, green: 0.70, blue: 0.32, alpha: 1))
    private let volDownButton = CineButton(title: "🔉 −", color: UIColor(red: 0.15, green: 0.55, blue: 0.90, alpha: 1), hitRadius: 0.24)
    private let volUpButton = CineButton(title: "🔊 +", color: UIColor(red: 0.15, green: 0.55, blue: 0.90, alpha: 1), hitRadius: 0.24)
    private let exitButton = CineButton(title: "🚪 ВЫХОД", color: UIColor(white: 0.28, alpha: 1))
    private let panelTitle = CineText()
    private let panelHint = CineText()

    private var previousPinch = false

    private var allButtons: [CineButton] {
        [lightButton, playButton, volDownButton, volUpButton, exitButton]
    }

    // MARK: Старт / стоп

    func start(in scene: SCNScene, cameraOrigin: SIMD3<Float>, cameraForward: SIMD3<Float>) {
        guard !isRunning else { return }
        isRunning = true
        self.scene = scene

        let forward = simd_normalize(SIMD3<Float>(cameraForward.x, 0, cameraForward.z))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))

        // Пол зала на 1.62 м ниже глаз, ось -Z смотрит на экран.
        root.simdPosition = simd_float3(
            cameraOrigin.x + forward.x * 1.0 + right.x * 0.0,
            cameraOrigin.y - 1.62,
            cameraOrigin.z + forward.z * 1.0 + right.z * 0.0
        )
        root.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward)

        root.childNodes.forEach { $0.removeFromParentNode() }
        ceilingStrips.removeAll()

        buildRoom()
        buildScreenArea()
        buildSeats()
        buildCeilingLights()
        buildControlPanel()

        // Общий свет зала: яркий при включённом свете, почти нулевой в темноте.
        ambientLight.type = .ambient
        ambientLight.color = UIColor(white: 1, alpha: 1)
        let lightNode = SCNNode()
        lightNode.light = ambientLight
        root.addChildNode(lightNode)
        setLights(lightsOn)

        scene.rootNode.addChildNode(root)

        // Экран стоит впереди и смотрит на зрителя (нормаль +Z к пользователю).
        var localScreen = matrix_identity_float4x4
        localScreen.columns.3 = SIMD4<Float>(0, 1.6, -Self.screenDistance, 1)
        screenWorldTransform = simd_mul(root.simdTransform, localScreen)

        previousPinch = false
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        root.removeFromParentNode()
        ceilingStrips.removeAll()
        scene = nil
    }

    // MARK: Постройка зала

    private func buildRoom() {
        let floorMat = SCNMaterial(); floorMat.cineLit(UIColor(red: 0.10, green: 0.09, blue: 0.16, alpha: 1))
        let wallMat = SCNMaterial(); wallMat.cineLit(UIColor(red: 0.14, green: 0.10, blue: 0.20, alpha: 1))
        let ceilMat = SCNMaterial(); ceilMat.cineLit(UIColor(red: 0.05, green: 0.04, blue: 0.09, alpha: 1))

        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ mat: SCNMaterial) -> SCNNode {
            let g = SCNBox(width: w, height: h, length: l, chamferRadius: 0)
            g.materials = [mat]
            return SCNNode(geometry: g)
        }

        let floor = box(7.6, 0.1, 8.2, floorMat); floor.position = SCNVector3(0, -0.05, -0.6)
        let ceiling = box(7.6, 0.1, 8.2, ceilMat); ceiling.position = SCNVector3(0, 3.25, -0.6)
        let backWall = box(7.6, 3.4, 0.12, wallMat); backWall.position = SCNVector3(0, 1.7, 3.5)
        let frontWall = box(7.6, 3.4, 0.12, wallMat); frontWall.position = SCNVector3(0, 1.7, -4.7)
        let leftWall = box(0.12, 3.4, 8.2, wallMat); leftWall.position = SCNVector3(-3.8, 1.7, -0.6)
        let rightWall = box(0.12, 3.4, 8.2, wallMat); rightWall.position = SCNVector3(3.8, 1.7, -0.6)

        [floor, ceiling, backWall, frontWall, leftWall, rightWall].forEach { root.addChildNode($0) }
    }

    private func buildScreenArea() {
        // Мягкое свечение вокруг экрана.
        let glowPlane = SCNPlane(width: CGFloat(Self.screenWidth) + 0.5, height: CGFloat(Self.screenHeight) + 0.5)
        let glowMat = SCNMaterial()
        glowMat.cineConstant(UIColor(white: 0.75, alpha: 1), emissive: 0.35)
        glowMat.isDoubleSided = true
        glowPlane.materials = [glowMat]
        let glow = SCNNode(geometry: glowPlane)
        glow.position = SCNVector3(0, 1.6, -Double(Self.screenDistance) - 0.12)
        root.addChildNode(glow)

        // Тёмные «шторы» по бокам.
        let curtainMat = SCNMaterial(); curtainMat.cineLit(UIColor(red: 0.32, green: 0.06, blue: 0.10, alpha: 1))
        for side in [-1.0, 1.0] {
            let curtain = SCNBox(width: 0.55, height: 3.2, length: 0.18, chamferRadius: 0.03)
            curtain.materials = [curtainMat]
            let node = SCNNode(geometry: curtain)
            node.position = SCNVector3(2.75 * side, 1.6, -Double(Self.screenDistance) - 0.15)
            root.addChildNode(node)
        }

        // Подпись над экраном.
        let sign = CineText()
        sign.setText("🎬 HANDAR CINEMA", color: UIColor(red: 0.9, green: 0.8, blue: 1, alpha: 1))
        sign.position = SCNVector3(0, 2.95, -Double(Self.screenDistance))
        sign.fitWidth(3.0)
        root.addChildNode(sign)
    }

    private func buildSeats() {
        let cushionMat = SCNMaterial(); cushionMat.cineLit(UIColor(red: 0.42, green: 0.08, blue: 0.11, alpha: 1))
        let frameMat = SCNMaterial(); frameMat.cineLit(UIColor(red: 0.16, green: 0.14, blue: 0.18, alpha: 1))

        let xs: [Float] = [-2.7, -1.8, -0.9, 0.9, 1.8, 2.7]
        let zs: [Float] = [-0.9, -1.8, -2.7]

        for z in zs {
            for x in xs {
                let seat = SCNNode()
                seat.position = SCNVector3(x, 0, z)

                // Постамент
                let base = SCNBox(width: 0.5, height: 0.42, length: 0.46, chamferRadius: 0.02)
                base.materials = [frameMat]
                let baseNode = SCNNode(geometry: base)
                baseNode.position = SCNVector3(0, 0.21, 0)
                seat.addChildNode(baseNode)

                // Сидушка
                let cushion = SCNBox(width: 0.56, height: 0.12, length: 0.5, chamferRadius: 0.05)
                cushion.materials = [cushionMat]
                let cushionNode = SCNNode(geometry: cushion)
                cushionNode.position = SCNVector3(0, 0.48, 0)
                seat.addChildNode(cushionNode)

                // Спинка
                let back = SCNBox(width: 0.56, height: 0.62, length: 0.12, chamferRadius: 0.04)
                back.materials = [cushionMat]
                let backNode = SCNNode(geometry: back)
                backNode.position = SCNVector3(0, 0.85, 0.23)
                backNode.eulerAngles.x = -0.14
                seat.addChildNode(backNode)

                // Подлокотники
                for side in [-1.0, 1.0] {
                    let arm = SCNBox(width: 0.07, height: 0.1, length: 0.46, chamferRadius: 0.03)
                    arm.materials = [frameMat]
                    let armNode = SCNNode(geometry: arm)
                    armNode.position = SCNVector3(0.315 * side, 0.62, 0)
                    seat.addChildNode(armNode)
                }

                root.addChildNode(seat)
            }
        }
    }

    private func buildCeilingLights() {
        let stripMat = SCNMaterial()
        stripMat.cineConstant(UIColor(white: 1, alpha: 1), emissive: 0.9)
        for z in [-1.0, -2.2, -3.0] as [Float] {
            let strip = SCNBox(width: 0.22, height: 0.08, length: 4.4, chamferRadius: 0.02)
            strip.materials = [stripMat]
            let node = SCNNode(geometry: strip)
            node.position = SCNVector3(0, 3.12, z)
            root.addChildNode(node)
            ceilingStrips.append(node)
        }
    }

    private func buildControlPanel() {
        // Панель за спиной: зритель разворачивается и указывает пальцем.
        let z: Float = 2.3

        panelTitle.setText("🎛 ПАНЕЛЬ УПРАВЛЕНИЯ", color: UIColor(red: 0.7, green: 0.85, blue: 1, alpha: 1))
        panelTitle.position = SCNVector3(0, 2.5, z)
        panelTitle.scale = SCNVector3(0.0034, 0.0034, 0.0034)
        root.addChildNode(panelTitle)

        panelHint.setText("Свет · Пауза · Громкость · Выход", color: UIColor(white: 0.8, alpha: 1))
        panelHint.position = SCNVector3(0, 2.18, z)
        panelHint.scale = SCNVector3(0.0022, 0.0022, 0.0022)
        root.addChildNode(panelHint)

        let buttons: [(CineButton, Float)] = [
            (lightButton, -1.6),
            (playButton, -0.8),
            (volDownButton, 0.0),
            (volUpButton, 0.8),
            (exitButton, 1.6)
        ]
        for (button, x) in buttons {
            button.node.position = SCNVector3(x, 1.6, z)
            root.addChildNode(button.node)
        }
    }

    // MARK: Управление

    func setLights(_ on: Bool) {
        lightsOn = on
        ambientLight.intensity = on ? 900 : 120
        for strip in ceilingStrips {
            let material = strip.geometry?.firstMaterial
            material?.diffuse.contents = on
                ? UIColor(white: 1, alpha: 1)
                : UIColor(white: 0.16, alpha: 1)
            material?.emission.contents = on
                ? UIColor(white: 1, alpha: 0.9)
                : UIColor(white: 0.1, alpha: 1)
        }
    }

    func setPlayingState(_ playing: Bool) {
        playButton.setTitle(playing ? "⏸ ПАУЗА" : "▶ ИГРАТЬ")
    }

    @discardableResult
    func update(ray: WorldRay?, pinch: Bool) -> Bool {
        guard isRunning else { return false }
        let pressed = pinch && !previousPinch
        previousPinch = pinch

        for button in allButtons { button.setHighlight(false) }
        if let ray {
            for button in allButtons where button.hitTest(ray: ray) {
                button.setHighlight(true)
                break
            }
        }

        guard pressed, let ray else { return false }

        if lightButton.hitTest(ray: ray) {
            setLights(!lightsOn)
            onToggleLights?(lightsOn)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if playButton.hitTest(ray: ray) {
            onPlayPause?()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        }
        if volUpButton.hitTest(ray: ray) {
            onVolume?(0.15)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if volDownButton.hitTest(ray: ray) {
            onVolume?(-0.15)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if exitButton.hitTest(ray: ray) {
            onExitRequested?()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        }
        return false
    }
}
