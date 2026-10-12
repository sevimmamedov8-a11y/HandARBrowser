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
    private let width: Float
    private let height: Float

    init(title: String, color: UIColor, width: Float = 0.34, height: Float = 0.168, hitRadius: Float = 0.2) {
        self.base = color
        self.hitRadius = hitRadius
        self.width = width
        self.height = height

        let box = SCNBox(width: CGFloat(width), height: CGFloat(height), length: 0.026, chamferRadius: 0.024)
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
        guard let image = renderTextImage(title, color: .white, fontSize: 48, weight: .bold) else {
            textNode.isHidden = true
            return
        }
        let plane = SCNPlane(width: image.size.width, height: image.size.height)
        let material = SCNMaterial()
        material.cineConstant(.white)
        material.diffuse.contents = image
        plane.materials = [material]
        textNode.geometry = plane
        let fit = Float(min(
            CGFloat(width) * 0.88 / Double(image.size.width),
            CGFloat(height) * 0.68 / Double(image.size.height)
        ))
        textNode.scale = SCNVector3(fit, fit, fit)
        textNode.position = SCNVector3(0, 0, 0.022)
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

// MARK: - Кинотеатр ----------------------------------------------------------

/// Полноценный 3D-кинозал IMAX: широкий экран, кресла с подлокотниками,
/// кресло зрителя, потолочный свет, неон, шторы и компактный пульт за спиной.
final class CinemaHall {

    /// Размер экрана. 4.55 × 2.56 м на 4 м — почти как в IMAX.
    static let screenWidth: Float = 4.55
    static let screenHeight: Float = 2.56
    static let screenDistance: Float = 4.0
    /// Высота глаз сидящего зрителя.
    static let seatedEyeHeight: Float = 1.18

    var onExitRequested: (() -> Void)?
    var onToggleLights: ((Bool) -> Void)?
    var onPlayPause: (() -> Void)?
    var onVolume: ((Float) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onRestart: (() -> Void)?

    private(set) var isRunning = false
    private(set) var lightsOn = true
    /// Мировая позиция и ориентация экрана — сюда MainViewController ставит
    /// браузерную панель/плеер.
    private(set) var screenWorldTransform = matrix_identity_float4x4

    private weak var scene: SCNScene?
    private let root = SCNNode()
    private let ambientLight = SCNLight()

    private var ceilingStrips: [SCNNode] = []
    private var neonNodes: [SCNMaterial] = []
    private var roomMaterials: [SCNMaterial] = []
    private let timeLabel = CineText()
    /// Подпись под экраном: загрузка либо подсказка, если поток не отдан.
    private let noticeLabel = CineText()

    private let lightButton = CineButton(title: "💡 СВЕТ", color: UIColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 1))
    private let playButton = CineButton(title: "⏯ ПАУЗА", color: UIColor(red: 0.15, green: 0.70, blue: 0.32, alpha: 1))
    private let backButton = CineButton(title: "⏪ −10с", color: UIColor(white: 0.34, alpha: 1))
    private let fwdButton = CineButton(title: "⏩ +10с", color: UIColor(white: 0.34, alpha: 1))
    private let volDownButton = CineButton(title: "🔉", color: UIColor(red: 0.15, green: 0.55, blue: 0.90, alpha: 1))
    private let volUpButton = CineButton(title: "🔊", color: UIColor(red: 0.15, green: 0.55, blue: 0.90, alpha: 1))
    private let restartButton = CineButton(title: "🔁", color: UIColor(white: 0.34, alpha: 1))
    private let exitButton = CineButton(title: "🚪 ВЫХОД", color: UIColor(red: 0.80, green: 0.18, blue: 0.26, alpha: 1))
    private let panelTitle = CineText()
    private let panelHint = CineText()

    private var previousPinch = false

    private var allButtons: [CineButton] {
        [lightButton, playButton, backButton, fwdButton,
         volDownButton, volUpButton, restartButton, exitButton]
    }

    // MARK: Старт / стоп

    func start(in scene: SCNScene, cameraOrigin: SIMD3<Float>, cameraForward: SIMD3<Float>) {
        guard !isRunning else { return }
        isRunning = true
        self.scene = scene

        let forward = simd_normalize(SIMD3<Float>(cameraForward.x, 0, cameraForward.z))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))

        // Пол зала — на высоте сидящего зрения, ось -Z смотрит на экран.
        root.simdPosition = simd_float3(
            cameraOrigin.x + forward.x * 0.0 + right.x * 0.0,
            cameraOrigin.y - Self.seatedEyeHeight,
            cameraOrigin.z + forward.z * 0.0 + right.z * 0.0
        )
        root.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward)

        root.childNodes.forEach { $0.removeFromParentNode() }
        ceilingStrips.removeAll()
        neonNodes.removeAll()
        roomMaterials.removeAll()

        buildRoom()
        buildScreenArea()
        buildSeats()
        buildCeilingLights()
        buildAestheticDetails()
        buildControlPanel()

        ambientLight.type = .ambient
        // Тёплый, а не белый: холодный свет выдаёт «сахар» и режет глаза.
        ambientLight.color = UIColor(red: 1, green: 0.93, blue: 0.82, alpha: 1)
        let lightNode = SCNNode()
        lightNode.light = ambientLight
        root.addChildNode(lightNode)
        setLights(lightsOn)

        scene.rootNode.addChildNode(root)

        // Экран впереди, нормаль смотрит на зрителя.
        var localScreen = matrix_identity_float4x4
        localScreen.columns.3 = SIMD4<Float>(0, Self.seatedEyeHeight, -Self.screenDistance, 1)
        screenWorldTransform = simd_mul(root.simdTransform, localScreen)

        previousPinch = false
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        root.removeFromParentNode()
        ceilingStrips.removeAll()
        neonNodes.removeAll()
        roomMaterials.removeAll()
        scene = nil
    }

    /// Показывает время под экраном: «⏱ 01:23 / 04:56».
    func setTime(current: Double, duration: Double) {
        guard duration > 0.5 else {
            timeLabel.setText("")
            return
        }
        timeLabel.setText("⏱ \(clock(current)) / \(clock(duration))")
    }

    /// Подпись под экраном: «загружаю…» или подсказка при сбое.
    func setNotice(_ text: String) {
        if text.isEmpty {
            noticeLabel.setText("")
            noticeLabel.isHidden = true
            return
        }
        noticeLabel.isHidden = false
        noticeLabel.setText("⚠️ \(text)", color: UIColor(red: 1, green: 0.76, blue: 0.42, alpha: 1))
        noticeLabel.fitWidth(2.7)
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Общий помощник для всех статичных коробок зала.
    private func boxNode(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ mat: SCNMaterial) -> SCNNode {
        let g = SCNBox(width: w, height: h, length: l, chamferRadius: 0)
        g.materials = [mat]
        return SCNNode(geometry: g)
    }

    /// Мелочи, из-за которых зал выглядит дорогим кинозалом, а не коробкой:
    /// звёздный потолок, светящийся периметр, акустика на стенах,
    /// тёплые лампы в проходах и дверные проёмы на задней стене.
    private func buildAestheticDetails() {
        // Светящийся периметр потолка — тянется по кромке зала.
        let ledEdgeMat = SCNMaterial()
        ledEdgeMat.lightingModel = .constant
        let edgeColor = UIColor(red: 0.52, green: 0.79, blue: 1, alpha: 1)
        ledEdgeMat.diffuse.contents = edgeColor
        ledEdgeMat.emission.contents = edgeColor

        let perimeter: [(Float, Float, Float, CGFloat, CGFloat, CGFloat)] = [
            (-6.6, 4.15, -1.0, 13.2, 0.05, 0.05),
            (6.6, 4.15, -1.0, 13.2, 0.05, 0.05),
            (0.0, 4.15, 7.86, 13.3, 0.05, 0.05),
            (0.0, 4.15, -9.86, 13.3, 0.05, 0.05)
        ]
        for (px, py, pz, w, h, l) in perimeter {
            let strip = boxNode(w, h, l, ledEdgeMat)
            strip.position = SCNVector3(px, py, pz)
            root.addChildNode(strip)
            ceilingStrips.append(strip)
        }

        // Звёздное небо: мелкие тёплые точки, рядки по потолку.
        let starMat = SCNMaterial()
        starMat.lightingModel = .constant
        let starColor = UIColor(red: 1, green: 0.92, blue: 0.76, alpha: 1)
        starMat.diffuse.contents = starColor
        starMat.emission.contents = starColor

        var starIndex: Float = 0
        while starIndex < 44 {
            let row = (starIndex / 11.0).rounded()
            let col = starIndex.truncatingRemainder(dividingBy: 11.0)
            let jitter = (starIndex * 0.37).truncatingRemainder(dividingBy: 1.0)
            let x: Float = -6.0 + col * 1.2 + jitter * 0.5
            let y: Float = 4.11
            let z: Float = -9.4 + row * 1.9
            let dot = SCNSphere(radius: 0.030)
            dot.materials = [starMat]
            let node = SCNNode(geometry: dot)
            node.position = SCNVector3(x, y, z)
            root.addChildNode(node)
            ceilingStrips.append(node)
            starIndex += 1
        }

        // Акустические панели по боковым стенам.
        let acousticMat = SCNMaterial()
        acousticMat.cineLit(UIColor(red: 0.11, green: 0.10, blue: 0.18, alpha: 1))
        for side in [-1.0, 1.0] {
            let sideX: Float = Float(side) * 6.72
            var row = 0
            while row < 3 {
                var col = 0
                while col < 10 {
                    let mat = boxNode(0.09, 0.60, 1.32, acousticMat)
                    let y: Float = 1.88 + Float(row) * 0.78
                    let z: Float = -8.4 + Float(col) * 1.72
                    mat.position = SCNVector3(sideX, y, z)
                    root.addChildNode(mat)
                    col += 1
                }
                row += 1
            }
        }

        // Тёплые лампы в проходах между рядами.
        let lampMat = SCNMaterial()
        lampMat.lightingModel = .constant
        let lampColor = UIColor(red: 1, green: 0.80, blue: 0.52, alpha: 1)
        lampMat.diffuse.contents = lampColor
        lampMat.emission.contents = lampColor
        let postMat = SCNMaterial()
        postMat.cineLit(UIColor(white: 0.09, alpha: 1))
        for side in [-1.0, 1.0] {
            let sideX: Float = Float(side) * 3.42
            var i = 0
            while i < 4 {
                let z: Float = 1.85 + Float(i) * 1.55
                let glow = SCNSphere(radius: 0.083)
                glow.materials = [lampMat]
                let glowNode = SCNNode(geometry: glow)
                glowNode.position = SCNVector3(sideX, 0.74, z)
                root.addChildNode(glowNode)
                ceilingStrips.append(glowNode)

                let post = boxNode(0.035, 0.74, 0.035, postMat)
                post.position = SCNVector3(sideX, 0.37, z)
                root.addChildNode(post)
                i += 1
            }
        }

        // Дверные арки на задней стене: зал перестаёт выглядеть глухой коробкой.
        let archMat = SCNMaterial()
        archMat.cineConstant(UIColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1))
        let signMat = SCNMaterial()
        signMat.lightingModel = .constant
        let signColor = UIColor(red: 0.26, green: 1, blue: 0.46, alpha: 1)
        signMat.diffuse.contents = signColor
        signMat.emission.contents = signColor
        for side in [-1.0, 1.0] {
            let archX: Float = Float(side) * 3.15
            let opening = boxNode(1.18, 2.32, 0.14, archMat)
            opening.position = SCNVector3(archX, 1.16, 7.90)
            root.addChildNode(opening)

            let sign = boxNode(0.52, 0.17, 0.03, signMat)
            sign.position = SCNVector3(archX, 2.62, 7.82)
            root.addChildNode(sign)
            ceilingStrips.append(sign)
        }
    }

    // MARK: Постройка зала

    private func buildRoom() {
        let floorMat = SCNMaterial(); floorMat.cineLit(UIColor(red: 0.09, green: 0.08, blue: 0.15, alpha: 1))
        let wallMat = SCNMaterial(); wallMat.cineLit(UIColor(red: 0.15, green: 0.11, blue: 0.22, alpha: 1))
        let wainscotMat = SCNMaterial(); wainscotMat.cineLit(UIColor(red: 0.24, green: 0.10, blue: 0.16, alpha: 1))
        let ceilMat = SCNMaterial(); ceilMat.cineLit(UIColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1))
        let carpetMat = SCNMaterial(); carpetMat.cineLit(UIColor(red: 0.34, green: 0.07, blue: 0.10, alpha: 1))
        roomMaterials = [floorMat, wallMat, wainscotMat, ceilMat, carpetMat]

        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ mat: SCNMaterial) -> SCNNode {
            let g = SCNBox(width: w, height: h, length: l, chamferRadius: 0)
            g.materials = [mat]
            return SCNNode(geometry: g)
        }

        let floor = box(14, 0.2, 18, floorMat); floor.position = SCNVector3(0, -0.1, -1.0)
        let ceiling = box(14, 0.2, 18, ceilMat); ceiling.position = SCNVector3(0, 4.2, -1.0)
        let backWall = box(14, 4.4, 0.12, wallMat); backWall.position = SCNVector3(0, 2.2, 8.0)
        let frontWall = box(14, 4.4, 0.12, wallMat); frontWall.position = SCNVector3(0, 2.2, -10.0)
        let leftWall = box(0.12, 4.4, 18, wallMat); leftWall.position = SCNVector3(-7.0, 2.2, -1.0)
        let rightWall = box(0.12, 4.4, 18, wallMat); rightWall.position = SCNVector3(7.0, 2.2, -1.0)
        [floor, ceiling, backWall, frontWall, leftWall, rightWall].forEach { root.addChildNode($0) }

        // Тёмные панели по низу стен и красная дорожка к экрану.
        for side in [-1.0, 1.0] {
            let wainscot = box(0.06, 1.0, 18, wainscotMat)
            wainscot.position = SCNVector3(6.9 * Float(side), 0.5, -1.0)
            root.addChildNode(wainscot)
        }
        let carpet = box(2.6, 0.03, 13.5, carpetMat)
        carpet.position = SCNVector3(0, 0.015, -3.6)
        root.addChildNode(carpet)

        // Неоновая подсветка по бокам.
        let neonCyan = SCNMaterial()
        neonCyan.lightingModel = .constant
        neonCyan.diffuse.contents = UIColor(red: 0.25, green: 0.9, blue: 1, alpha: 1)
        neonCyan.emission.contents = UIColor(red: 0.25, green: 0.9, blue: 1, alpha: 1)
        let neonMagenta = SCNMaterial()
        neonMagenta.lightingModel = .constant
        neonMagenta.diffuse.contents = UIColor(red: 1, green: 0.30, blue: 0.78, alpha: 1)
        neonMagenta.emission.contents = UIColor(red: 1, green: 0.30, blue: 0.78, alpha: 1)
        neonNodes = [neonCyan, neonMagenta]
        for (index, side) in [-1.0, 1.0].enumerated() {
            let strip = box(0.07, 0.09, 16, index == 0 ? neonCyan : neonMagenta)
            strip.position = SCNVector3(6.82 * Float(side), 1.6, -1.0)
            root.addChildNode(strip)
        }

        // Постеры на задней стене.
        let boardMat = SCNMaterial(); boardMat.cineLit(UIColor(red: 0.07, green: 0.07, blue: 0.13, alpha: 1))
        let frameEdgeMat = SCNMaterial()
        frameEdgeMat.lightingModel = .constant
        let frameColor = UIColor(red: 0.62, green: 0.45, blue: 0.20, alpha: 1)
        frameEdgeMat.diffuse.contents = frameColor
        frameEdgeMat.emission.contents = frameColor
        let posters: [(Float, String)] = [
            (-3.4, "🎬 ЛУЧШИЕ ФИЛЬМЫ"),
            (0.0, "🍿 БЕСПЛАТНЫЙ ПОПКОРН"),
            (3.4, "🎟 БИЛЕТЫ ПРОДАНЫ")
        ]
        for (x, text) in posters {
            let poster = CineText()
            poster.setText(text, color: UIColor(red: 0.75, green: 0.85, blue: 1, alpha: 1))
            poster.position = SCNVector3(x, 2.4, 7.85)
            poster.fitWidth(2.1)
            root.addChildNode(poster)

            // Подложка-щит под постером: текст читается, а постеры не висят в воздухе.
            let board = box(2.35, 1.08, 0.045, boardMat)
            board.position = SCNVector3(x, 2.4, 7.89)
            root.addChildNode(board)
            let frame = box(2.45, 1.18, 0.03, frameEdgeMat)
            frame.position = SCNVector3(x, 2.4, 7.92)
            root.addChildNode(frame)
        }
    }

    private func buildScreenArea() {
        let bezelMat = SCNMaterial(); bezelMat.cineConstant(UIColor(white: 0.04, alpha: 1))
        let ledMat = SCNMaterial()
        ledMat.lightingModel = .constant
        ledMat.diffuse.contents = UIColor(red: 0.35, green: 0.75, blue: 1, alpha: 1)
        ledMat.emission.contents = UIColor(red: 0.35, green: 0.75, blue: 1, alpha: 1)

        let screenZ = -Self.screenDistance
        let bezel = SCNBox(
            width: CGFloat(Self.screenWidth) + 0.22,
            height: CGFloat(Self.screenHeight) + 0.22,
            length: 0.10,
            chamferRadius: 0.02
        )
        bezel.materials = [bezelMat]
        let bezelNode = SCNNode(geometry: bezel)
        bezelNode.position = SCNVector3(0, Self.seatedEyeHeight, screenZ - 0.02)
        root.addChildNode(bezelNode)

        // Светодиодная окантовка экрана.
        let ledPositions: [(Float, Float, Float)] = [
            (0, Self.seatedEyeHeight + (Self.screenHeight + 0.10) * 0.5, screenZ - 0.09),
            (0, Self.seatedEyeHeight - (Self.screenHeight + 0.10) * 0.5, screenZ - 0.09)
        ]
        for (x, y, z) in ledPositions {
            let strip = SCNBox(
                width: CGFloat(Self.screenWidth) + 0.14,
                height: 0.035, length: 0.02,
                chamferRadius: 0.01
            )
            strip.materials = [ledMat]
            let node = SCNNode(geometry: strip)
            node.position = SCNVector3(x, y, z)
            root.addChildNode(node)
        }
        for side in [-1.0, 1.0] {
            let strip = SCNBox(
                width: 0.035, height: CGFloat(Self.screenHeight) + 0.14, length: 0.02,
                chamferRadius: 0.01
            )
            strip.materials = [ledMat]
            let node = SCNNode(geometry: strip)
            let edgeX: Float = Float(side) * (Self.screenWidth + 0.10) * 0.5
            node.position = SCNVector3(edgeX, Self.seatedEyeHeight, screenZ - 0.09)
            root.addChildNode(node)
        }

        // Мягкое свечение вокруг экрана.
        let glowPlane = SCNPlane(
            width: CGFloat(Self.screenWidth) + 2.2,
            height: CGFloat(Self.screenHeight) + 1.6
        )
        let glowMat = SCNMaterial()
        glowMat.cineConstant(UIColor(red: 0.20, green: 0.42, blue: 0.95, alpha: 1), emissive: 0.30)
        glowMat.isDoubleSided = true
        glowPlane.materials = [glowMat]
        let glow = SCNNode(geometry: glowPlane)
        glow.position = SCNVector3(0, Self.seatedEyeHeight, screenZ - 0.16)
        root.addChildNode(glow)

        // Шторы по бокам экрана.
        let curtainMat = SCNMaterial(); curtainMat.cineLit(UIColor(red: 0.36, green: 0.06, blue: 0.11, alpha: 1))
        for side in [-1.0, 1.0] {
            let curtain = SCNBox(width: 0.75, height: 4.0, length: 0.22, chamferRadius: 0.04)
            curtain.materials = [curtainMat]
            let node = SCNNode(geometry: curtain)
            node.position = SCNVector3(3.9 * Float(side), 2.0, screenZ - 0.25)
            root.addChildNode(node)
        }

        // Вывеска и время сеанса под экраном.
        let sign = CineText()
        sign.setText("🎬 HANDAR IMAX", color: UIColor(red: 0.92, green: 0.82, blue: 1, alpha: 1))
        sign.position = SCNVector3(0, Self.seatedEyeHeight + Self.screenHeight * 0.5 + 0.55, screenZ + 0.05)
        sign.fitWidth(3.2)
        root.addChildNode(sign)

        timeLabel.position = SCNVector3(0, 0.42, screenZ + 0.55)
        timeLabel.fitWidth(1.9)
        root.addChildNode(timeLabel)

        // Подпись-предупреждение — строкой под картинкой, как субтитры.
        noticeLabel.position = SCNVector3(
            0,
            Self.seatedEyeHeight - Self.screenHeight * 0.5 - 0.42,
            screenZ + 0.08
        )
        noticeLabel.isHidden = true
        root.addChildNode(noticeLabel)
    }

    private func buildSeats() {
        let cushionMat = SCNMaterial(); cushionMat.cineLit(UIColor(red: 0.44, green: 0.08, blue: 0.12, alpha: 1))
        let frameMat = SCNMaterial(); frameMat.cineLit(UIColor(red: 0.17, green: 0.15, blue: 0.20, alpha: 1))

        func makeSeat(x: Float, z: Float, wide: Bool) {
            let seat = SCNNode()
            seat.position = SCNVector3(x, 0, z)
            let w: Float = wide ? 0.86 : 0.62
            let d: Float = wide ? 0.54 : 0.46

            let base = SCNBox(width: CGFloat(w - 0.02), height: 0.44, length: CGFloat(d - 0.02), chamferRadius: 0.02)
            base.materials = [frameMat]
            let baseNode = SCNNode(geometry: base)
            baseNode.position = SCNVector3(0, 0.22, 0)
            seat.addChildNode(baseNode)

            let cushion = SCNBox(width: CGFloat(w), height: 0.13, length: CGFloat(d), chamferRadius: 0.05)
            cushion.materials = [cushionMat]
            let cushionNode = SCNNode(geometry: cushion)
            cushionNode.position = SCNVector3(0, 0.50, 0)
            seat.addChildNode(cushionNode)

            let back = SCNBox(width: CGFloat(w), height: 0.66, length: 0.13, chamferRadius: 0.04)
            back.materials = [cushionMat]
            let backNode = SCNNode(geometry: back)
            backNode.position = SCNVector3(0, 0.90, d * 0.46)
            backNode.eulerAngles.x = -0.13
            seat.addChildNode(backNode)

            for side in [-1.0, 1.0] {
                let arm = SCNBox(width: 0.08, height: 0.11, length: CGFloat(d), chamferRadius: 0.03)
                arm.materials = [frameMat]
                let armNode = SCNNode(geometry: arm)
                armNode.position = SCNVector3(Float(side) * (w * 0.5 + 0.03), 0.64, 0)
                seat.addChildNode(armNode)
            }
            root.addChildNode(seat)
        }

        // Кресло зрителя — широкое, с подстаканниками.
        makeSeat(x: 0, z: 0.78, wide: true)
        let holderMat = SCNMaterial(); holderMat.cineConstant(UIColor(red: 0.10, green: 0.35, blue: 0.75, alpha: 1), emissive: 0.35)
        for side in [-1.0, 1.0] {
            let holder = SCNCylinder(radius: 0.05, height: 0.05)
            holder.materials = [holderMat]
            let node = SCNNode(geometry: holder)
            node.position = SCNVector3(Float(side) * 0.62, 0.70, 0.78)
            root.addChildNode(node)
        }

        // Обычные ряды: 4 ряда по 7 кресел.
        let xs: [Float] = [-2.76, -1.84, -0.92, 0.0, 0.92, 1.84, 2.76]
        for row in 0..<4 {
            let z = 2.35 + Float(row) * 1.05
            for x in xs {
                makeSeat(x: x, z: z, wide: false)
            }
        }
    }

    private func buildCeilingLights() {
        let stripMat = SCNMaterial()
        stripMat.cineConstant(UIColor(white: 1, alpha: 1), emissive: 0.9)
        for z in [-1.5, 0.5, 2.5, 4.5] as [Float] {
            let strip = SCNBox(width: 0.26, height: 0.07, length: 6.0, chamferRadius: 0.02)
            strip.materials = [stripMat]
            let node = SCNNode(geometry: strip)
            node.position = SCNVector3(0, 4.02, z)
            root.addChildNode(node)
            ceilingStrips.append(node)
        }
        // Тёплые боконцы у экрана.
        for side in [-1.0, 1.0] {
            let lamp = SCNBox(width: 0.18, height: 0.10, length: 0.6, chamferRadius: 0.03)
            lamp.materials = [stripMat]
            let node = SCNNode(geometry: lamp)
            node.position = SCNVector3(4.4 * Float(side), 3.1, -Self.screenDistance + 0.4)
            root.addChildNode(node)
            ceilingStrips.append(node)
        }
    }

    private func buildControlPanel() {
        // Компактная панель сразу за креслом зрителя.
        let z: Float = 1.62

        panelTitle.setText("🎛 ПУЛЬТ", color: UIColor(red: 0.72, green: 0.86, blue: 1, alpha: 1))
        panelTitle.position = SCNVector3(0, 1.74, z)
        panelTitle.scale = SCNVector3(0.0026, 0.0026, 0.0026)
        root.addChildNode(panelTitle)

        panelHint.setText("повернись и укажи пальцем", color: UIColor(white: 0.78, alpha: 1))
        panelHint.position = SCNVector3(0, 1.58, z)
        panelHint.scale = SCNVector3(0.0016, 0.0016, 0.0016)
        root.addChildNode(panelHint)

        let columns: [Float] = [-0.51, -0.17, 0.17, 0.51]
        let rows: [Float] = [1.38, 1.14]

        func place(_ button: CineButton, column: Int, row: Int) {
            button.node.position = SCNVector3(columns[column], rows[row], z)
            root.addChildNode(button.node)
        }

        place(lightButton, column: 0, row: 0)
        place(playButton, column: 1, row: 0)
        place(backButton, column: 2, row: 0)
        place(fwdButton, column: 3, row: 0)
        place(volDownButton, column: 0, row: 1)
        place(volUpButton, column: 1, row: 1)
        place(restartButton, column: 2, row: 1)
        place(exitButton, column: 3, row: 1)
    }

    // MARK: Управление

    func setLights(_ on: Bool) {
        lightsOn = on
        ambientLight.intensity = on ? 900 : 130
        for strip in ceilingStrips {
            let material = strip.geometry?.firstMaterial
            material?.diffuse.contents = on ? UIColor(white: 1, alpha: 1) : UIColor(white: 0.14, alpha: 1)
            material?.emission.contents = on
                ? UIColor(white: 1, alpha: 0.9)
                : UIColor(white: 0.08, alpha: 1)
        }
        for material in neonNodes {
            material.emission.contents = on
                ? (material.diffuse.contents as? UIColor ?? UIColor.white)
                : ((material.diffuse.contents as? UIColor)?.withAlphaComponent(0.18) ?? UIColor.white)
        }
    }

    func setPlayingState(_ playing: Bool) {
        playButton.setTitle(playing ? "⏯ ПАУЗА" : "▶ ИГРАТЬ")
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
        if backButton.hitTest(ray: ray) {
            onSeek?(-10)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if fwdButton.hitTest(ray: ray) {
            onSeek?(10)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        if restartButton.hitTest(ray: ray) {
            onRestart?()
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
