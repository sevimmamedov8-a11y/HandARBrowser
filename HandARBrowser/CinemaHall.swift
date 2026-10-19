import SceneKit
import simd
import UIKit

/// Small shared progress ring for native spatial controls. Geometry is rebuilt
/// only when its 1/30 step changes, never once per rendered eye.
final class DwellProgressRing: SCNNode {
    private var step = -1
    func show(on target: SCNNode?, progress: Double) {
        guard let target, progress > 0 else { isHidden=true;return }
        if parent !== target { removeFromParentNode();target.addChildNode(self) }
        position=SCNVector3(0,0.11,0.04)
        isHidden=false
        let next=Int(min(1,progress)*30)
        guard step != next else { return };step=next
        let end=CGFloat.pi/2-CGFloat(max(1,next))/30*2*CGFloat.pi
        let path=UIBezierPath()
        path.addArc(withCenter:.zero,radius:0.027,startAngle:.pi/2,endAngle:end,clockwise:false)
        path.addArc(withCenter:.zero,radius:0.021,startAngle:end,endAngle:.pi/2,clockwise:true)
        path.close()
        let shape=SCNShape(path:path,extrusionDepth:0)
        let material=SCNMaterial();material.lightingModel = .constant
        material.diffuse.contents=UIColor(red:0.55,green:0.86,blue:1,alpha:1)
        material.isDoubleSided=true;material.readsFromDepthBuffer=false;material.writesToDepthBuffer=false
        shape.firstMaterial=material;geometry=shape;renderingOrder=100
    }
}

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
    private let plate: SCNNode
    private let textNode = SCNNode()
    private var currentTitle: String?
    private let base: UIColor
    private let width: Float
    private let height: Float

    init(title: String, color: UIColor, width: Float = 0.46, height: Float = 0.22) {
        self.base = color
        self.width = width
        self.height = height

        let box = SCNBox(width: CGFloat(width), height: CGFloat(height), length: 0.026, chamferRadius: 0.024)
        let material = SCNMaterial()
        material.cineConstant(color.withAlphaComponent(0.78), emissive: 0.10)
        material.blendMode = .alpha
        box.materials = [material]
        plate = SCNNode(geometry: box)
        node.addChildNode(plate)
        node.addChildNode(textNode)
        node.constraints = [SCNBillboardConstraint()]
        setTitle(title)
    }

    func setTitle(_ title: String) {
        guard currentTitle != title else { return }
        guard let image = renderTextImage(title, color: .white, fontSize: 48, weight: .medium) else {
            textNode.isHidden = true
            return
        }
        currentTitle = title
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
        // Hit the visible plate, not overlapping spheres around neighboring buttons.
        let inverse=node.presentation.simdWorldTransform.inverse
        let origin=inverse * SIMD4<Float>(ray.origin,1)
        let direction=inverse * SIMD4<Float>(ray.direction,0)
        guard abs(direction.z)>0.00001 else { return false }
        let t = -origin.z/direction.z
        guard t>0 else { return false }
        let hit=origin+direction*t
        return abs(hit.x)<=width*0.5+0.025 && abs(hit.y)<=height*0.5+0.025
    }

    func setHighlight(_ highlighted: Bool) {
        let material = plate.geometry?.firstMaterial
        material?.diffuse.contents = highlighted
            ? UIColor(red:0.24,green:0.34,blue:0.37,alpha:1)
            : base.withAlphaComponent(0.95)
        material?.emission.contents = highlighted
            ? base.withAlphaComponent(0.9)
            : base.withAlphaComponent(0.22)
    }
}

// MARK: - Кинотеатр ----------------------------------------------------------

/// Объёмный 3D-кинозал: широкий экран, кресла с подлокотниками,
/// кресло зрителя, потолочный свет, неон, шторы и компактный пульт под экраном.
final class CinemaHall {

    /// Размер экрана. 4.55 × 2.56 м на 4 м — почти как в IMAX.
    static let screenWidth: Float = 4.55
    static let screenHeight: Float = 2.56
    static let screenDistance: Float = 4.0
    static let screenCenterHeight: Float = 1.85

    var onExitRequested: (() -> Void)?
    var onToggleLights: ((Bool) -> Void)?
    var onPlayPause: (() -> Void)?
    var onInteraction: (() -> Void)?
    var onVolume: ((Float) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onRestart: (() -> Void)?

    private(set) var isRunning = false
    private(set) var lightsOn = false
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

    private let lightButton = CineButton(title: "Свет", color: UIColor(white: 0.17, alpha: 1))
    private let playButton = CineButton(title: "Пауза", color: UIColor(red:0.10,green:0.26,blue:0.27,alpha:1))
    private let backButton = CineButton(title: "⏪ −10с", color: UIColor(white: 0.15, alpha: 1))
    private let fwdButton = CineButton(title: "⏩ +10с", color: UIColor(white: 0.15, alpha: 1))
    private let volDownButton = CineButton(title: "− звук", color: UIColor(white: 0.17, alpha: 1))
    private let volUpButton = CineButton(title: "+ звук", color: UIColor(white: 0.17, alpha: 1))
    private let restartButton = CineButton(title: "Сначала", color: UIColor(white: 0.15, alpha: 1))
    private let exitButton = CineButton(title: "Домой", color: UIColor(white: 0.17, alpha: 1))
    private let panelTitle = CineText()

    private var buttonClickGate = ReleaseClickGate<ObjectIdentifier>()
    private let dwellRing = DwellProgressRing()

    private var allButtons: [CineButton] {
        [lightButton, playButton, backButton, fwdButton,
         volDownButton, volUpButton, restartButton, exitButton]
    }

    // MARK: Старт / стоп

    func start(in scene: SCNScene, cameraOrigin: SIMD3<Float>, cameraForward: SIMD3<Float>) {
        guard !isRunning else { return }
        cancelInput()
        isRunning = true
        self.scene = scene

        alignViewer(origin:cameraOrigin,forward:cameraForward)

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
        ambientLight.color = UIColor(red: 0.88, green: 0.92, blue: 1, alpha: 1)
        let lightNode = SCNNode()
        lightNode.light = ambientLight
        root.addChildNode(lightNode)
        setLights(lightsOn)

        scene.rootNode.addChildNode(root)

        updateScreenTransform()
    }

    private func updateScreenTransform() {
        var localScreen = matrix_identity_float4x4
        localScreen.columns.3 = SIMD4<Float>(0, Self.screenCenterHeight, -Self.screenDistance, 1)
        screenWorldTransform = simd_mul(root.simdTransform, localScreen)
    }

    func alignViewer(origin: SIMD3<Float>, forward direction: SIMD3<Float>) {
        let flat=SIMD3<Float>(direction.x,0,direction.z)
        let length=simd_length(flat)
        let forward=length.isFinite && length>0.0001 ? flat/length : SIMD3<Float>(0,0,-1)
        // The screen center starts straight ahead at the actual camera height.
        root.simdPosition=SIMD3(origin.x,origin.y-Self.screenCenterHeight,origin.z)
        root.simdOrientation=simd_quatf(from:SIMD3<Float>(0,0,-1),to:forward)
        updateScreenTransform()
    }

    func stop() {
        cancelInput()
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
        timeLabel.setText("\(clock(current)) / \(clock(duration))")
        timeLabel.fitWidth(0.92)
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
        let edgeColor = UIColor(red:0.32,green:0.24,blue:0.15,alpha:1)
        ledEdgeMat.diffuse.contents = edgeColor
        ledEdgeMat.emission.contents = UIColor.black

        let perimeter: [(Float, Float, Float, CGFloat, CGFloat, CGFloat)] = [
            (-6.6, 4.08, -1.0, 0.035, 0.035, 17.7),
            (6.6, 4.08, -1.0, 0.035, 0.035, 17.7),
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
            let row = (starIndex / 11.0).rounded(.down)
            let col = starIndex.truncatingRemainder(dividingBy: 11.0)
            let jitter = (starIndex * 0.37).truncatingRemainder(dividingBy: 1.0)
            let x: Float = -6.0 + col * 1.2 + jitter * 0.5
            let y: Float = 4.11
            let z: Float = -9.4 + row * 1.9
            let dot = SCNSphere(radius: 0.012)
            dot.segmentCount=6
            dot.materials = [starMat]
            let node = SCNNode(geometry: dot)
            node.position = SCNVector3(x, y, z)
            root.addChildNode(node)
            ceilingStrips.append(node)
            starIndex += 1
        }

        // Акустические панели по боковым стенам.
        let acousticMat = SCNMaterial()
        acousticMat.cineLit(UIColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1))
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
        let floorMat = SCNMaterial(); floorMat.cineLit(UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1))
        let wallMat = SCNMaterial(); wallMat.cineLit(UIColor(red: 0.16, green: 0.19, blue: 0.23, alpha: 1))
        let wainscotMat = SCNMaterial(); wainscotMat.cineLit(UIColor(red: 0.23, green: 0.15, blue: 0.10, alpha: 1))
        let ceilMat = SCNMaterial(); ceilMat.cineLit(UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1))
        let carpetMat = SCNMaterial(); carpetMat.cineLit(UIColor(red: 0.09, green: 0.17, blue: 0.18, alpha: 1))
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
        neonCyan.diffuse.contents = UIColor(red:0.30,green:0.22,blue:0.12,alpha:1)
        neonCyan.emission.contents = UIColor(red:0.30,green:0.22,blue:0.12,alpha:1)
        let neonMagenta = SCNMaterial()
        neonMagenta.lightingModel = .constant
        neonMagenta.diffuse.contents = UIColor(red:0.30,green:0.22,blue:0.12,alpha:1)
        neonMagenta.emission.contents = UIColor(red:0.30,green:0.22,blue:0.12,alpha:1)
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
            (-3.4, "HANDAR CINEMA"),
            (0.0, "ПРИЯТНОГО ПРОСМОТРА"),
            (3.4, "ЛИЧНЫЙ ЗАЛ")
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
        ledMat.diffuse.contents = UIColor(red:0.22,green:0.16,blue:0.09,alpha:1)
        ledMat.emission.contents = UIColor.black

        let screenZ = -Self.screenDistance
        let bezel = SCNBox(
            width: CGFloat(Self.screenWidth) + 0.22,
            height: CGFloat(Self.screenHeight) + 0.22,
            length: 0.10,
            chamferRadius: 0.02
        )
        bezel.materials = [bezelMat]
        let bezelNode = SCNNode(geometry: bezel)
        bezelNode.position = SCNVector3(0, Self.screenCenterHeight, screenZ - 0.02)
        root.addChildNode(bezelNode)

        // Светодиодная окантовка экрана.
        let ledPositions: [(Float, Float, Float)] = [
            (0, Self.screenCenterHeight + (Self.screenHeight + 0.10) * 0.5, screenZ - 0.09),
            (0, Self.screenCenterHeight - (Self.screenHeight + 0.10) * 0.5, screenZ - 0.09)
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
            node.position = SCNVector3(edgeX, Self.screenCenterHeight, screenZ - 0.09)
            root.addChildNode(node)
        }

        // Matte surround: the former opaque blue "glow" plane filled the view.
        let surroundMat=SCNMaterial()
        surroundMat.cineConstant(UIColor(red:0.025,green:0.032,blue:0.042,alpha:1))
        let surround=boxNode(CGFloat(Self.screenWidth)+1.25,CGFloat(Self.screenHeight)+0.65,0.08,surroundMat)
        surround.position=SCNVector3(0,Self.screenCenterHeight,screenZ-0.18)
        root.addChildNode(surround)

        // Шторы по бокам экрана.
        let curtainMat = SCNMaterial(); curtainMat.cineLit(UIColor(red:0.16,green:0.065,blue:0.085,alpha:1))
        for side in [-1.0, 1.0] {
            let curtain = SCNBox(width: 0.75, height: 4.0, length: 0.22, chamferRadius: 0.04)
            curtain.materials = [curtainMat]
            let node = SCNNode(geometry: curtain)
            node.position = SCNVector3(3.9 * Float(side), 2.0, screenZ - 0.25)
            root.addChildNode(node)
        }

        // Вывеска и время сеанса под экраном.
        let sign = CineText()
        sign.setText("HandAR Cinema", color: UIColor(red: 0.92, green: 0.82, blue: 1, alpha: 1))
        sign.position = SCNVector3(0, Self.screenCenterHeight + Self.screenHeight * 0.5 + 0.55, screenZ + 0.05)
        sign.fitWidth(1.8)
        root.addChildNode(sign)

        // Подпись-предупреждение — строкой под картинкой, как субтитры.
        noticeLabel.position = SCNVector3(
            0,
            Self.screenCenterHeight - Self.screenHeight * 0.5 - 0.42,
            screenZ + 0.08
        )
        noticeLabel.isHidden = true
        root.addChildNode(noticeLabel)
    }

    private func buildSeats() {
        let cushionMat = SCNMaterial(); cushionMat.cineLit(UIColor(red: 0.10, green: 0.25, blue: 0.25, alpha: 1))
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
        let material=SCNMaterial()
        material.cineConstant(UIColor(red:0.42,green:0.30,blue:0.18,alpha:1))
        for side in [-1.0,1.0] {
            let strip=boxNode(0.045,0.035,14,material)
            strip.position=SCNVector3(Float(side)*5.8,4.04,-0.8)
            root.addChildNode(strip);ceilingStrips.append(strip)
        }
    }

    private func buildControlPanel() {
        // In front, below the raised screen. Buttons have separated hit areas
        // and are large enough to keep a dwell on a single target.
        let z: Float = -2.6
        let panelMat=SCNMaterial()
        panelMat.cineConstant(UIColor(red:0.035,green:0.045,blue:0.055,alpha:1))
        let plate=SCNBox(width:2.38,height:0.86,length:0.035,chamferRadius:0.07)
        plate.firstMaterial=panelMat
        let panel=SCNNode(geometry:plate)
        panel.position=SCNVector3(0,0.32,z-0.05);root.addChildNode(panel)

        panelTitle.setText("УПРАВЛЕНИЕ",color:UIColor(white:0.60,alpha:1))
        panelTitle.position=SCNVector3(-0.65,0.68,z+0.015);panelTitle.fitWidth(0.77)
        root.addChildNode(panelTitle)
        timeLabel.position=SCNVector3(0.63,0.68,z+0.015)
        timeLabel.fitWidth(0.92);root.addChildNode(timeLabel)

        let columns: [Float] = [-0.87,-0.29,0.29,0.87]
        let rows: [Float] = [0.44,0.11]
        func place(_ button: CineButton, column: Int, row: Int) {
            button.node.position=SCNVector3(columns[column],rows[row],z)
            root.addChildNode(button.node)
        }
        place(backButton,column:0,row:0)
        place(playButton,column:1,row:0)
        place(fwdButton,column:2,row:0)
        place(lightButton,column:3,row:0)
        place(volDownButton,column:0,row:1)
        place(volUpButton,column:1,row:1)
        place(restartButton,column:2,row:1)
        place(exitButton,column:3,row:1)
    }

    // MARK: Управление

    func setLights(_ on: Bool) {
        lightsOn = on
        ambientLight.intensity = on ? 400 : 180
        lightButton.setTitle(on ? "Свет: ярче" : "Свет: мягко")
        // Preserve each lamp's designed color. Never replace every material
        // with white, and use node opacity rather than multiplying shared colors.
        for strip in ceilingStrips { strip.opacity = on ? 0.7 : 0.25 }
        for material in neonNodes { material.emission.contents = UIColor.black }
    }

    func setPlayingState(_ playing: Bool) {
        playButton.setTitle(playing ? "Пауза" : "Смотреть")
    }

    func setSoundEnabled(_ enabled: Bool) {
        volUpButton.setTitle(enabled ? "+ звук" : "Вкл звук")
    }

    func cancelInput() {
        buttonClickGate.cancel()
        dwellRing.isHidden=true
        for button in allButtons { button.setHighlight(false) }
    }

    @discardableResult
    func update(ray: WorldRay?, pinch: Bool, allowBegin: Bool = true, dwell: Bool = false) -> Bool {
        guard isRunning else { return false }
        let target = ray.flatMap { ray in allButtons.first { $0.hitTest(ray:ray) } }
        for button in allButtons { button.setHighlight(button === target) }
        let committed=buttonClickGate.update(target:target.map { ObjectIdentifier($0) },down:pinch,allowBegin:allowBegin,dwell:dwell,at:CACurrentMediaTime())
        dwellRing.show(on:target?.node,progress:buttonClickGate.dwellProgress)
        guard committed != nil, let target else { return target != nil }
        onInteraction?()

        if target === lightButton {
            setLights(!lightsOn)
            onToggleLights?(lightsOn)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if target === playButton {
            onPlayPause?()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        }
        if target === backButton {
            onSeek?(-10)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if target === fwdButton {
            onSeek?(10)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if target === volUpButton {
            onVolume?(0.15)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if target === volDownButton {
            onVolume?(-0.15)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if target === restartButton {
            onRestart?()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return true
        }
        if target === exitButton {
            onExitRequested?()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        }
        return false
    }
}
