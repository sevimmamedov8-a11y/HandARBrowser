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
final class CineText: SCNNode {
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
final class CineButton {
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
            ? UIColor(red:0.20,green:0.30,blue:0.48,alpha:1)
            : base.withAlphaComponent(0.95)
        material?.emission.contents = highlighted
            ? base.withAlphaComponent(0.9)
            : base.withAlphaComponent(0.22)
    }
}

// MARK: - Кинотеатр ----------------------------------------------------------

/// Session-only comfort actions. Deadlines use the monotonic frame clock.
struct CinemaComfortState {
    private(set) var isReclined = false
    private(set) var isPeeking = false
    private(set) var reclineDeadline: Double?
    private(set) var remoteDeadline: Double?
    var remoteSummoned: Bool { remoteDeadline != nil }

    mutating func requestRecline(at time: Double) -> Bool {
        guard time.isFinite, !isPeeking else { return false }
        if reclineDeadline != nil { reclineDeadline = nil; return false }
        if isReclined { isReclined = false; return true }
        reclineDeadline = time + 3
        return false
    }
    mutating func setPeeking(_ value: Bool) {
        isPeeking = value
        reclineDeadline = nil
        remoteDeadline = nil
    }
    mutating func toggleRemote(at time: Double) {
        guard time.isFinite, !isPeeking else { return }
        remoteDeadline = remoteSummoned ? nil : time + 12
    }
    mutating func keepRemote(at time: Double) {
        if remoteSummoned, time.isFinite { remoteDeadline = time + 12 }
    }
    mutating func dismissRemote() { remoteDeadline = nil }
    mutating func cancelRecline() { reclineDeadline = nil }
    mutating func advance(at time: Double) -> (realign: Bool, restoreRemote: Bool) {
        guard time.isFinite else { return (false, false) }
        var realign = false, restore = false
        if let deadline = reclineDeadline, time >= deadline {
            reclineDeadline = nil
            // A suspended frame stream must not unexpectedly rotate the room later.
            if time - deadline < 0.5 { isReclined = true; realign = true }
        }
        if let deadline = remoteDeadline, time >= deadline {
            remoteDeadline = nil; restore = true
        }
        return (realign, restore)
    }
}

/// Dimensions in metres; the camera sits in row five, facing the screen.
/// The visual reference is the blue auditorium photographed at Gənclik Mall.
/// These are reconstructed proportions, not an architectural survey.
enum CinemaHallLayout {
    static let screenWidth: Float = 6.4
    static let screenHeight: Float = 3.6
    static let screenDistance: Float = 7.6
    static let screenCenterHeight: Float = 2.4
    static let roomHalfWidth: Float = 6.3
    static let frontZ: Float = -8.0
    static let backZ: Float = 6.5
    static let ceilingHeight: Float = 5.8
    static let rowCount = 9
    static let viewerRow = 4
    static let rowPitch: Float = 1.3
    static let rowRise: Float = 0.3
    static let seatPitch: Float = 0.82
    static let remotePosition = SIMD3<Float>(1.4, 2.35, -0.65)
    static let remoteScale: Float = 0.8
    static let remoteWidth: Float = 1.16
    static let remoteHeight: Float = 1.58

    static func rowZ(_ row: Int) -> Float { Float(row - viewerRow) * rowPitch }
    static func rowFloor(_ row: Int) -> Float { Float(row) * rowRise }
    static func buttonCenter(_ index: Int) -> SIMD3<Float> {
        SIMD3(index % 2 == 0 ? -0.29 : 0.29, 0.37 - Float(index / 2) * 0.32, 0.04)
    }
}

/// Blue tiered auditorium and a fixed, inward-facing remote at the right seat arm.
final class CinemaHall {
    static let screenWidth = CinemaHallLayout.screenWidth
    static let screenHeight = CinemaHallLayout.screenHeight
    static let screenDistance = CinemaHallLayout.screenDistance
    static let screenCenterHeight = CinemaHallLayout.screenCenterHeight

    var onExitRequested: (() -> Void)?
    var onToggleLights: ((Bool) -> Void)?
    var onPlayPause: (() -> Void)?
    var onInteraction: (() -> Void)?
    var onVolume: ((Float) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onRestart: (() -> Void)?
    var onRemoteRequested: (() -> Void)?
    var onPeekRequested: (() -> Void)?
    var onRealignRequested: (() -> Void)?
    private(set) var comfort = CinemaComfortState()
    private let comfortRoot = SCNNode()
    private var remotePanel: SCNNode?
    private var latchedComfortButton: CineButton?
    private let summonButton = CineButton(title: "Пульт", color: UIColor(white: 0.12, alpha: 1))
    private let reclineButton = CineButton(title: "Полулёжа", color: UIColor(white: 0.12, alpha: 1))
    private let peekButton = CineButton(title: "Камера", color: UIColor(white: 0.12, alpha: 1))
    private var comfortButtons: [CineButton] { [summonButton, reclineButton, peekButton] }

    private(set) var isRunning = false
    private(set) var lightsOn = false
    /// Мировая позиция и ориентация экрана — сюда MainViewController ставит
    /// браузерную панель/плеер.
    private(set) var screenWorldTransform = matrix_identity_float4x4

    private weak var scene: SCNScene?
    private let root = SCNNode()
    private let ambientLight = SCNLight()

    private var ceilingStrips: [SCNNode] = []
    private let timeLabel = CineText()
    /// Подпись под экраном: загрузка либо подсказка, если поток не отдан.
    private let noticeLabel = CineText()

    private let lightButton = CineButton(title: "Свет", color: UIColor(white: 0.17, alpha: 1))
    private let playButton = CineButton(title: "Пауза", color: UIColor(red:0.10,green:0.19,blue:0.34,alpha:1))
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
         volDownButton, volUpButton, restartButton, exitButton] + comfortButtons
    }

    // MARK: Старт / стоп

    func start(in scene: SCNScene, cameraOrigin: SIMD3<Float>, cameraForward: SIMD3<Float>) {
        guard !isRunning else { return }
        cancelInput()
        isRunning = true
        comfort = CinemaComfortState()
        latchedComfortButton = nil
        root.isHidden = false
        self.scene = scene

        alignViewer(origin:cameraOrigin,forward:cameraForward)

        root.childNodes.forEach { $0.removeFromParentNode() }
        ceilingStrips.removeAll()

        buildRoom()
        buildScreenArea()
        buildSeats()
        buildAestheticDetails()
        buildControlPanel()

        ambientLight.type = .ambient
        // A cool, low ambient fill preserves blue fabric without white glare.
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

    /// Rotate the room around the seated eye, never around its floor origin.
    func alignReclinedViewer(origin: SIMD3<Float>, forward direction: SIMD3<Float>) {
        let length = simd_length(direction)
        guard length.isFinite, length > 0.0001 else { return }
        let rotation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: direction / length)
        root.simdOrientation = rotation
        root.simdPosition = origin - rotation.act(SIMD3<Float>(0, Self.screenCenterHeight, 0))
        updateScreenTransform()
    }

    func attachComfortControls(to head: SCNNode) {
        comfortRoot.removeFromParentNode()
        comfortRoot.childNodes.forEach { $0.removeFromParentNode() }
        comfortRoot.position = SCNVector3(0, -0.53, -1.55)
        comfortRoot.scale = SCNVector3(0.78, 0.78, 0.78)
        let plateMaterial = SCNMaterial()
        plateMaterial.cineConstant(UIColor(white: 0.035, alpha: 1))
        let plate = boxNode(1.64, 0.29, 0.025, plateMaterial)
        plate.position.z = -0.03
        comfortRoot.addChildNode(plate)
        for (index, button) in comfortButtons.enumerated() {
            button.node.constraints = []
            button.node.position = SCNVector3(Float(index - 1) * 0.56, 0, 0)
            comfortRoot.addChildNode(button.node)
        }
        head.addChildNode(comfortRoot)
        refreshComfortTitles(at: CACurrentMediaTime())
    }

    /// A head-locked button cannot be reached by a head-directed ray. Keep
    /// this dock at the entrance/recenter pose while hands are resting.
    func setHeadAiming(_ enabled: Bool, head: SCNNode) {
        guard isRunning, let scene else { return }
        comfortRoot.removeFromParentNode()
        comfortRoot.simdOrientation = simd_quatf()
        comfortRoot.position = SCNVector3(0, -0.53, -1.55)
        comfortRoot.scale = SCNVector3(0.78, 0.78, 0.78)
        head.addChildNode(comfortRoot)
        if enabled {
            let transform = comfortRoot.simdWorldTransform
            comfortRoot.removeFromParentNode()
            scene.rootNode.addChildNode(comfortRoot)
            comfortRoot.simdWorldTransform = transform
        }
        cancelInput()
    }

    /// Native controls need holes in the live UIKit video surface above SceneKit.
    var overlayPanels: [(transform: simd_float4x4, width: Float, height: Float)] {
        guard isRunning, !comfort.isPeeking else { return [] }
        var panels = [(comfortRoot.simdWorldTransform, Float(1.68), Float(0.33))]
        if let panel = remotePanel {
            panels.append((panel.simdWorldTransform, CinemaHallLayout.remoteWidth + 0.06,
                           CinemaHallLayout.remoteHeight + 0.06))
        }
        return panels
    }

    func refreshComfortTitles(at time: Double) {
        summonButton.setTitle(comfort.remoteSummoned ? "Убрать" : "Пульт")
        if let deadline = comfort.reclineDeadline {
            reclineButton.setTitle("Через \(max(1, Int(ceil(deadline - time))))с")
        } else {
            reclineButton.setTitle(comfort.isReclined ? "Сидя" : "Полулёжа")
        }
        peekButton.setTitle(comfort.isPeeking ? "В зал" : "Камера")
        summonButton.node.opacity = comfort.isPeeking ? 0.3 : 1
        reclineButton.node.opacity = comfort.isPeeking ? 0.3 : 1
    }

    func restoreRemote() {
        comfort.dismissRemote()
        guard let panel = remotePanel else { return }
        panel.simdPosition = CinemaHallLayout.remotePosition
        let eye = SIMD3<Float>(0, Self.screenCenterHeight, 0)
        panel.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1),
                                        to: simd_normalize(eye - CinemaHallLayout.remotePosition))
        let scale = CinemaHallLayout.remoteScale
        panel.scale = SCNVector3(scale, scale, scale)
        refreshComfortTitles(at: CACurrentMediaTime())
    }

    func toggleRemote(headTransform: simd_float4x4, at time: Double) {
        guard isRunning, !comfort.isPeeking, let panel = remotePanel else { return }
        cancelInput()
        comfort.toggleRemote(at: time)
        if comfort.remoteSummoned {
            var local = matrix_identity_float4x4
            local.columns.0.x = CinemaHallLayout.remoteScale
            local.columns.1.y = CinemaHallLayout.remoteScale
            local.columns.2.z = CinemaHallLayout.remoteScale
            local.columns.3 = SIMD4<Float>(0, 0, -1.65, 1)
            panel.simdWorldTransform = simd_mul(headTransform, local)
        } else { restoreRemote() }
        refreshComfortTitles(at: time)
    }

    func setPeeking(_ value: Bool) {
        cancelInput()
        comfort.setPeeking(value)
        restoreRemote()
        root.isHidden = value
        refreshComfortTitles(at: CACurrentMediaTime())
    }

    func cancelPendingRecline() {
        comfort.cancelRecline()
        refreshComfortTitles(at: CACurrentMediaTime())
    }

    func tick(at time: Double) {
        guard isRunning else { return }
        let event = comfort.advance(at: time)
        if event.restoreRemote { cancelInput(); restoreRemote() }
        if event.realign { onRealignRequested?() }
        refreshComfortTitles(at: time)
    }

    func stop() {
        cancelInput()
        guard isRunning else { return }
        isRunning = false
        root.removeFromParentNode()
        comfortRoot.removeFromParentNode()
        remotePanel = nil
        comfort = CinemaComfortState()
        latchedComfortButton = nil
        ceilingStrips.removeAll()
        scene = nil
    }

    /// Playback time belongs to the remote, away from the movie.
    func setTime(current: Double, duration: Double) {
        guard duration > 0.5 else {
            timeLabel.setText("")
            return
        }
        timeLabel.setText("\(clock(current)) / \(clock(duration))")
        timeLabel.fitWidth(0.88)
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

    // MARK: Auditorium geometry

    private func buildRoom() {
        let wall = SCNMaterial()
        wall.cineLit(UIColor(red: 0.065, green: 0.09, blue: 0.29, alpha: 1))
        let dark = SCNMaterial()
        dark.cineLit(UIColor(red: 0.028, green: 0.031, blue: 0.043, alpha: 1))
        let carpet = SCNMaterial()
        carpet.cineLit(UIColor(red: 0.055, green: 0.06, blue: 0.08, alpha: 1))
        let architecture = SCNNode()
        let half = CinemaHallLayout.roomHalfWidth
        let depth = CinemaHallLayout.backZ - CinemaHallLayout.frontZ
        let centerZ = (CinemaHallLayout.backZ + CinemaHallLayout.frontZ) / 2
        let height = CinemaHallLayout.ceilingHeight
        func add(_ w: Float, _ h: Float, _ d: Float, _ position: SCNVector3, _ material: SCNMaterial) {
            let node = boxNode(CGFloat(w), CGFloat(h), CGFloat(d), material)
            node.position = position
            architecture.addChildNode(node)
        }
        add(half * 2, 0.2, depth, SCNVector3(0, -0.1, centerZ), carpet)
        add(half * 2, 0.15, depth, SCNVector3(0, height + 0.075, centerZ), dark)
        add(half * 2, height, 0.15, SCNVector3(0, height / 2, CinemaHallLayout.frontZ), dark)
        add(half * 2, height, 0.15, SCNVector3(0, height / 2, CinemaHallLayout.backZ), dark)
        for side: Float in [-1, 1] {
            add(0.15, height, depth, SCNVector3(side * half, height / 2, centerZ), wall)
            add(0.04, 1.2, depth, SCNVector3(side * (half - 0.09), 0.6, centerZ), dark)
        }
        // Raised seating decks include the two side aisles; no red central carpet.
        for row in 0..<CinemaHallLayout.rowCount {
            let top = CinemaHallLayout.rowFloor(row)
            let z = CinemaHallLayout.rowZ(row)
            add(11.8, top + 0.08, CinemaHallLayout.rowPitch,
                SCNVector3(0, (top - 0.08) / 2, z), carpet)
        }
        // The static architecture is batched; it does not change while viewing.
        root.addChildNode(architecture.flattenedClone())
    }

    private func buildAestheticDetails() {
        let fixtures = SCNNode()
        let accents = SCNNode()
        let black = SCNMaterial()
        black.cineLit(UIColor(white: 0.025, alpha: 1))
        let led = SCNMaterial()
        led.cineConstant(UIColor(red: 0.48, green: 0.55, blue: 0.95, alpha: 1))
        let stair = SCNMaterial()
        stair.cineConstant(UIColor(red: 0.31, green: 0.37, blue: 0.53, alpha: 1))

        // Thin broken vertical lines, as on the photographed blue side walls.
        // They are geometry, not dozens of shadow-casting lights or a bloom layer.
        for side: Float in [-1, 1] {
            let x = side * (CinemaHallLayout.roomHalfWidth - 0.12)
            for bay in 0..<8 {
                let z = -6.5 + Float(bay) * 1.6
                let bend: Float = bay % 2 == 0 ? 0.26 : -0.26
                let points = [SIMD3<Float>(x, 1.28, z), SIMD3<Float>(x, 2.85, z + bend),
                              SIMD3<Float>(x, 3.35, z - bend), SIMD3<Float>(x, 5.68, z)]
                for i in 0..<(points.count - 1) {
                    let delta = points[i + 1] - points[i]
                    let strip = boxNode(0.018, CGFloat(simd_length(delta)), 0.024, led)
                    strip.simdPosition = (points[i] + points[i + 1]) / 2
                    strip.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta))
                    accents.addChildNode(strip)
                }
                if bay % 2 == 0 {
                    let speaker = boxNode(0.2, 0.48, 0.32, black)
                    speaker.position = SCNVector3(x - side * 0.11, 3.25, z + 0.62)
                    fixtures.addChildNode(speaker)
                }
            }
            // Two half-steps per row: understated aisle edge lights.
            for row in 0..<CinemaHallLayout.rowCount {
                let z = CinemaHallLayout.rowZ(row)
                let top = CinemaHallLayout.rowFloor(row)
                let halfStep = boxNode(1.12, 0.15, 0.25, black)
                halfStep.position = SCNVector3(side * 5.15, top - 0.075, z - 0.77)
                fixtures.addChildNode(halfStep)
                for offset: Float in [-0.62, -0.87] {
                    let edge = boxNode(0.86, 0.018, 0.024, stair)
                    let y = offset < -0.7 ? top - 0.145 : top + 0.012
                    edge.position = SCNVector3(side * 5.15, max(0.018, y), z + offset)
                    accents.addChildNode(edge)
                }
            }
            let door = boxNode(0.06, 2.05, 1.02, black)
            door.position = SCNVector3(x, 1.025, -6.95)
            fixtures.addChildNode(door)
            let exit = CineText()
            exit.constraints = []
            exit.setText("ÇIXIŞ", color: UIColor(red: 0.24, green: 0.6, blue: 0.4, alpha: 1))
            exit.fitWidth(0.48)
            exit.position = SCNVector3(x - side * 0.05, 2.22, -6.95)
            exit.eulerAngles.y = side < 0 ? .pi / 2 : -.pi / 2
            root.addChildNode(exit)
        }
        root.addChildNode(fixtures.flattenedClone())
        let lightLines = accents.flattenedClone()
        root.addChildNode(lightLines)
        ceilingStrips.append(lightLines)
    }

    private func buildScreenArea() {
        let surround = SCNMaterial()
        surround.cineConstant(UIColor(white: 0.012, alpha: 1))
        // Entire front wall is matte; the image alone supplies the bright area.
        // Backing front face stays BEHIND z = -screenDistance (native video plane).
        let bezel = boxNode(CGFloat(Self.screenWidth + 0.16), CGFloat(Self.screenHeight + 0.16), 0.08, surround)
        bezel.position = SCNVector3(0, Self.screenCenterHeight, -Self.screenDistance - 0.055)
        root.addChildNode(bezel)
        let stage = boxNode(8.5, 0.18, 0.7, surround)
        stage.position = SCNVector3(0, 0.09, -Self.screenDistance + 0.1)
        root.addChildNode(stage)
        noticeLabel.constraints = []
        noticeLabel.position = SCNVector3(0, 0.32, -Self.screenDistance + 0.08)
        noticeLabel.isHidden = true
        root.addChildNode(noticeLabel)
    }

    private func buildSeats() {
        let blue = SCNMaterial()
        blue.cineLit(UIColor(red: 0.07, green: 0.15, blue: 0.43, alpha: 1))
        let inset = SCNMaterial()
        inset.cineLit(UIColor(red: 0.055, green: 0.105, blue: 0.29, alpha: 1))
        let shell = SCNMaterial()
        shell.cineLit(UIColor(red: 0.027, green: 0.03, blue: 0.04, alpha: 1))
        let cup = SCNMaterial()
        cup.cineConstant(UIColor(white: 0.018, alpha: 1))
        let template = SCNNode()
        func cushion(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ radius: CGFloat,
                     _ position: SCNVector3, _ material: SCNMaterial) -> SCNNode {
            let box = SCNBox(width: w, height: h, length: d, chamferRadius: radius)
            box.chamferSegmentCount = 2
            box.firstMaterial = material
            let node = SCNNode(geometry: box)
            node.position = position
            template.addChildNode(node)
            return node
        }
        _ = cushion(0.46, 0.4, 0.42, 0.02, SCNVector3(0, 0.2, 0), shell)
        _ = cushion(0.63, 0.13, 0.56, 0.05, SCNVector3(0, 0.48, -0.03), blue)
        let back = cushion(0.66, 0.67, 0.16, 0.07, SCNVector3(0, 0.74, 0.25), shell)
        back.eulerAngles.x = -0.1
        let upholstery = cushion(0.59, 0.60, 0.09, 0.045, SCNVector3(0, 0.75, 0.16), blue)
        upholstery.eulerAngles.x = -0.1
        _ = cushion(0.53, 0.18, 0.065, 0.03, SCNVector3(0, 0.96, 0.13), inset)
        // The exposed blue crown remains visible when looking over the rows.
        _ = cushion(0.58, 0.12, 0.13, 0.04, SCNVector3(0, 1.04, 0.25), blue)
        for side: Float in [-1, 1] {
            _ = cushion(0.105, 0.1, 0.56, 0.025, SCNVector3(side * 0.365, 0.62, -0.01), shell)
            let holder = SCNTorus(ringRadius: 0.037, pipeRadius: 0.008)
            holder.ringSegmentCount = 12
            holder.pipeSegmentCount = 4
            holder.firstMaterial = cup
            let node = SCNNode(geometry: holder)
            node.position = SCNVector3(side * 0.365, 0.675, -0.19)
            template.addChildNode(node)
        }
        // Reuse a single static mesh/material set across 99 seats. No per-frame
        // geometry, textures, shadow maps or individual lights for the chairs.
        let seat = template.flattenedClone()
        for row in 0..<CinemaHallLayout.rowCount {
            let seats = SCNNode()
            for column in -5...5 {
                let node = seat.clone()
                node.position = SCNVector3(Float(column) * CinemaHallLayout.seatPitch,
                                          CinemaHallLayout.rowFloor(row), CinemaHallLayout.rowZ(row))
                seats.addChildNode(node)
            }
            root.addChildNode(seats.flattenedClone())
        }
    }

    private func buildControlPanel() {
        let panel = SCNNode()
        panel.simdPosition = CinemaHallLayout.remotePosition
        let eye = SIMD3<Float>(0, Self.screenCenterHeight, 0)
        let facing = simd_normalize(eye - CinemaHallLayout.remotePosition)
        panel.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: facing)
        let scale = CinemaHallLayout.remoteScale
        panel.scale = SCNVector3(scale, scale, scale)
        root.addChildNode(panel)
        remotePanel = panel

        let material = SCNMaterial()
        material.cineConstant(UIColor(red: 0.032, green: 0.043, blue: 0.075, alpha: 1))
        let plate = SCNBox(width: CGFloat(CinemaHallLayout.remoteWidth),
                           height: CGFloat(CinemaHallLayout.remoteHeight), length: 0.055, chamferRadius: 0.065)
        plate.chamferSegmentCount = 3
        plate.firstMaterial = material
        panel.addChildNode(SCNNode(geometry: plate))
        panelTitle.constraints = []
        panelTitle.setText("ПУЛЬТ", color: UIColor(red: 0.59, green: 0.68, blue: 0.91, alpha: 1))
        panelTitle.position = SCNVector3(0, 0.66, 0.04)
        panelTitle.fitWidth(0.39)
        panel.addChildNode(panelTitle)
        timeLabel.constraints = []
        timeLabel.position = SCNVector3(0, 0.53, 0.04)
        timeLabel.fitWidth(0.88)
        panel.addChildNode(timeLabel)

        let buttons = [playButton, lightButton, backButton, fwdButton,
                       volDownButton, volUpButton, restartButton, exitButton]
        for (index, button) in buttons.enumerated() {
            // All controls use the SAME panel transform, including ray hit tests.
            // Independent billboards would rotate each key away from its plate.
            button.node.constraints = []
            button.node.simdPosition = CinemaHallLayout.buttonCenter(index)
            panel.addChildNode(button.node)
        }
    }

    // MARK: Управление

    func setLights(_ on: Bool) {
        lightsOn = on
        ambientLight.intensity = on ? 650 : 260
        lightButton.setTitle(on ? "Свет: ярче" : "Свет: мягко")
        // Preserve each lamp's designed color. Never replace every material
        // with white, and use node opacity rather than multiplying shared colors.
        for strip in ceilingStrips { strip.opacity = on ? 0.85 : 0.32 }
    }

    func setReloadAvailable(_ available: Bool) {
        restartButton.setTitle(available ? "Обновить" : "Сначала")
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
        let candidates = comfort.isPeeking ? [peekButton] : allButtons
        let target = ray.flatMap { ray in candidates.first { $0.hitTest(ray:ray) } }
        if let latched = latchedComfortButton {
            if target === latched { return true }
            latchedComfortButton = nil
        }
        if let target, !comfortButtons.contains(where: { $0 === target }) {
            comfort.keepRemote(at: CACurrentMediaTime())
        }
        for button in allButtons { button.setHighlight(button === target) }
        let committed=buttonClickGate.update(target:target.map { ObjectIdentifier($0) },down:pinch,allowBegin:allowBegin,dwell:dwell,at:CACurrentMediaTime())
        dwellRing.show(on:target?.node,progress:buttonClickGate.dwellProgress)
        guard committed != nil, let target else { return target != nil }
        onInteraction?()

        if comfortButtons.contains(where: { $0 === target }) {
            latchedComfortButton = target
            dwellRing.isHidden = true
            if target === summonButton { onRemoteRequested?() }
            if target === peekButton { onPeekRequested?() }
            if target === reclineButton {
                if comfort.requestRecline(at: CACurrentMediaTime()) { onRealignRequested?() }
                refreshComfortTitles(at: CACurrentMediaTime())
            }
            return true
        }
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
