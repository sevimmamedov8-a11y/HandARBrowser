import ARKit
import SceneKit
import UIKit
import simd

/// One persistent paint bitmap per surface, not one scene node per spray dot.
private final class GraffitiCanvas {
    let id = UUID()
    let node: SCNNode
    let size: SIMD2<Double>
    let base: UIColor
    private let width: Int
    private let height: Int
    private var context: CGContext?
    private(set) var dirty = false

    init(size: SIMD2<Double>, base: UIColor, textureWidth: Int = 1024) {
        self.size = size; self.base = base
        width = textureWidth
        height = max(1, Int(Double(textureWidth) * size.y / size.x))
        let plane = SCNPlane(width: CGFloat(size.x), height: CGFloat(size.y))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = base
        material.isDoubleSided = true
        material.writesToDepthBuffer = base.cgColor.alpha > 0
        material.diffuse.mipFilter = .linear
        plane.firstMaterial = material
        node = SCNNode(geometry: plane)
    }

    private func bitmap() -> CGContext? {
        if let context { return context }
        guard let created = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        created.setFillColor(base.cgColor)
        created.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context = created
        return created
    }

    func snapshot() -> CGImage? { bitmap()?.makeImage() }

    func restore(_ image: CGImage) {
        guard let context = bitmap() else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(rect); context.draw(image, in: rect)
        dirty = true
    }

    func spray(points: [SIMD2<Double>], radius: Double, color: UIColor, clip: [SIMD2<Double>]?) {
        guard let context = bitmap(), !points.isEmpty else { return }
        let scale = Double(width) / size.x
        func pixel(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x: (p.x + size.x * 0.5) * scale, y: (p.y + size.y * 0.5) * scale)
        }
        context.saveGState()
        if let clip, clip.count >= 3 {
            context.beginPath(); context.move(to: pixel(clip[0]))
            for point in clip.dropFirst() { context.addLine(to: pixel(point)) }
            context.closePath(); context.clip()
        }
        let colors = [color.withAlphaComponent(0.28).cgColor, color.withAlphaComponent(0.10).cgColor,
                      color.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
            for point in points {
                let center = pixel(point)
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: CGFloat(radius * scale), options: [])
            }
        }
        context.restoreGState(); dirty = true
    }

    func upload() {
        guard dirty, let image = context?.makeImage() else { return }
        node.geometry?.firstMaterial?.diffuse.contents = UIImage(cgImage: image)
        dirty = false
    }
}

final class GraffitiStudio {
    private let root = SCNNode(), room = SCNNode(), home = SCNNode(), ui = SCNNode(), panel = SCNNode()
    private let can = SCNNode(), mist = SCNNode(), aim = SCNNode()
    private let canMaterial = SCNMaterial()
    private let sculptureMaterial = SCNMaterial()
    private var roomAccents: [(SCNMaterial, Bool)] = []
    private var mood = GraffitiRoomMood.neon
    private var rainbow = false
    private let status = CineText()
    private let paletteButton = CineButton(title: "Цвет", color: .darkGray, width: 0.24, height: 0.16)
    private var buttons: [(String, CineButton)] = []
    private var uiGate = ReleaseClickGate<String>()
    private var uiHand: TrackedHand?
    private var uiBlocked = false
    private let ring = DwellProgressRing()
    private var sprayGate = GraffitiSprayGate()
    private var sampler = GraffitiStrokeSampler()
    private var roomCanvases: [GraffitiCanvas] = []
    private var homeCanvases: [GraffitiCanvas] = []
    private var canvasAnchors: [UUID: GraffitiCanvas] = [:]
    private var paintAnchors: [ARAnchor] = []
    private var undo: [(UUID, CGImage)] = []
    private var activeCanvas: UUID?
    private var lastHandAt: Double = -.infinity
    private var lastUpload: Double = -.infinity
    private var paletteOpen = false
    private var aligned = false
    private var hint = ""
    private var colorIndex = 0, sizeIndex = 1
    private let radii = [0.018, 0.045, 0.09]
    private let colors: [(String, UIColor)] = [
        ("Красный", .systemRed), ("Оранж", .systemOrange), ("Жёлтый", .systemYellow), ("Зелёный", .systemGreen),
        ("Голубой", .systemCyan), ("Фиолет", .systemPurple), ("Белый", .white), ("Чёрный", .black)]
    private(set) var isRunning = false
    private(set) var mode: GraffitiMode = .room
    private(set) var paintingHand: TrackedHand?
    var handOwner: TrackedHand? { sprayGate.owner }
    func showsVirtualHand(_ hand: TrackedHand) -> Bool { paintingHand != hand }
    var onExit: (() -> Void)?
    var onModeChanged: ((GraffitiMode) -> Void)?
    var onInteraction: (() -> Void)?
    var onAddAnchor: ((ARAnchor) -> Void)?
    var onRemoveAnchor: ((ARAnchor) -> Void)?
    var wallHit: ((WorldRay) -> ARRaycastResult?)?

    init() {
        root.addChildNode(room); root.addChildNode(home); root.addChildNode(ui)
        root.addChildNode(can); root.addChildNode(aim)
        ui.addChildNode(panel); ui.addChildNode(paletteButton.node); ui.addChildNode(status)
        paletteButton.node.position = SCNVector3(0.59, -0.30, -1.15)
        status.position = SCNVector3(0, -0.86, -1.5)
        buildPalette(); buildCan()
        let target = SCNTorus(ringRadius: 0.018, pipeRadius: 0.002)
        target.firstMaterial = material(.white)
        aim.geometry = target; aim.eulerAngles.x = .pi / 2
        aim.isHidden = true
    }

    private func material(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = color
        m.isDoubleSided = true
        return m
    }

    private func box(_ size: SCNVector3, at position: SCNVector3, color: UIColor, parent: SCNNode) {
        let geometry = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.01)
        geometry.firstMaterial = material(color)
        let node = SCNNode(geometry: geometry); node.position = position; parent.addChildNode(node)
    }

    private func buildCan() {
        can.scale = SCNVector3(0.62, 0.62, 0.62)
        let body = SCNCylinder(radius: 0.035, height: 0.15)
        canMaterial.lightingModel = .constant; body.firstMaterial = canMaterial
        can.addChildNode(SCNNode(geometry: body))
        for y: Float in [-0.078, 0.078] {
            let rim = SCNTorus(ringRadius: 0.031, pipeRadius: 0.005)
            rim.firstMaterial = material(UIColor(white: 0.8, alpha: 1))
            let node = SCNNode(geometry: rim); node.position.y = y; can.addChildNode(node)
        }
        box(SCNVector3(0.026, 0.025, 0.026), at: SCNVector3(0, 0.09, 0), color: .darkGray, parent: can)
        box(SCNVector3(0.012, 0.009, 0.012), at: SCNVector3(0, 0.09, -0.018), color: .white, parent: can)
        let plume = SCNCone(topRadius: 0.003, bottomRadius: 0.025, height: 0.1)
        plume.firstMaterial = material(.white.withAlphaComponent(0.15))
        plume.firstMaterial?.writesToDepthBuffer = false
        mist.geometry = plume; mist.eulerAngles.x = .pi / 2
        mist.position = SCNVector3(0, 0.09, -0.07); can.addChildNode(mist)
        can.isHidden = true; mist.isHidden = true
    }

    private func buildPalette() {
        box(SCNVector3(1.12, 1.20, 0.035), at: SCNVector3(0, -0.11, -1.36),
            color: UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.97), parent: panel)
        func button(_ id: String, _ title: String, _ x: Float, _ y: Float, _ color: UIColor = .darkGray, width: Float = 0.25) {
            let b = CineButton(title: title, color: color, width: width, height: 0.14)
            b.node.position = SCNVector3(x, y, -1.32); panel.addChildNode(b.node); buttons.append((id, b))
        }
        for (index, entry) in colors.enumerated() {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
            entry.1.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let swatch = UIColor(red: red * 0.45, green: green * 0.45, blue: blue * 0.45, alpha: 1)
            button("color-\(index)", entry.0, Float(index % 4) * 0.27 - 0.405, 0.34 - Float(index / 4) * 0.17, swatch)
        }
        for (index, title) in ["Тонко", "Средне", "Широко"].enumerated() {
            button("size-\(index)", title, Float(index - 1) * 0.34, -0.02, width: 0.31)
        }
        button("room", "Комната", -0.27, -0.20, width: 0.49)
        button("home", "Мои стены", 0.27, -0.20, width: 0.49)
        button("rainbow", "Радуга: выкл", -0.27, -0.38, width: 0.49)
        button("mood", "Свет: Неон", 0.27, -0.38, width: 0.49)
        button("undo", "Отменить", -0.27, -0.56, width: 0.49)
        button("exit", "В меню", 0.27, -0.56, width: 0.49)
        panel.isHidden = true
    }

    private func buildRoomDecor() {
        // Static props are merged once. Paint canvases and the animated sculpture
        // stay separate so changing a color never rebuilds the room.
        let decor = SCNNode()
        let span = GraffitiRoomLayout.span, half = span * 0.5
        let floor = GraffitiRoomLayout.floorY, ceiling = GraffitiRoomLayout.ceilingY
        let charcoal = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        let metal = UIColor(red: 0.26, green: 0.30, blue: 0.36, alpha: 1)
        let cyan = UIColor(red: 0.18, green: 0.79, blue: 0.90, alpha: 1)
        let violet = UIColor(red: 0.69, green: 0.38, blue: 0.91, alpha: 1)
        box(SCNVector3(span + 0.05, 0.05, span + 0.05), at: SCNVector3(0, floor, 0), color: charcoal, parent: decor)
        box(SCNVector3(span + 0.05, 0.05, span + 0.05), at: SCNVector3(0, ceiling, 0), color: UIColor(white: 0.09, alpha: 1), parent: decor)
        for offset in -3...3 {
            let line = UIColor(white: 0.19, alpha: 1)
            box(SCNVector3(0.012, 0.004, span), at: SCNVector3(Float(offset), floor + 0.027, 0), color: line, parent: decor)
            box(SCNVector3(span, 0.004, 0.012), at: SCNVector3(0, floor + 0.027, Float(offset)), color: line, parent: decor)
        }
        for side: Float in [-1, 1] {
            let edge = side * (half - 0.04)
            let accent = side < 0 ? cyan : violet
            for y in [floor + 0.10, ceiling - 0.08] {
                box(SCNVector3(0.06, 0.08, span), at: SCNVector3(edge, y, 0), color: metal, parent: decor)
                box(SCNVector3(span, 0.08, 0.06), at: SCNVector3(0, y, edge), color: metal, parent: decor)
            }
            box(SCNVector3(0.018, 0.025, span - 0.3), at: SCNVector3(edge - side * 0.04, ceiling - 0.14, 0), color: accent, parent: decor)
            for z: Float in [-half + 0.08, half - 0.08] {
                box(SCNVector3(0.05, GraffitiRoomLayout.wallHeight - 0.3, 0.05),
                    at: SCNVector3(edge, GraffitiRoomLayout.wallCenterY, z), color: accent, parent: decor)
            }
            box(SCNVector3(1.2, 0.06, 2.6), at: SCNVector3(side * 1.8, ceiling - 0.07, -0.3), color: metal, parent: decor)
            box(SCNVector3(1.08, 0.015, 2.48), at: SCNVector3(side * 1.8, ceiling - 0.11, -0.3),
                color: UIColor(red: 0.83, green: 0.88, blue: 0.91, alpha: 1), parent: decor)
        }
        let standingRing = SCNTorus(ringRadius: 0.65, pipeRadius: 0.009)
        standingRing.ringSegmentCount = 48; standingRing.pipeSegmentCount = 6
        standingRing.firstMaterial = material(UIColor(white: 0.43, alpha: 1))
        let marker = SCNNode(geometry: standingRing)
        marker.position.y = floor + 0.04; decor.addChildNode(marker)

        // Rear workbench leaves the front and side painting areas clear.
        box(SCNVector3(2.5, 0.09, 0.65), at: SCNVector3(-1.65, floor + 0.85, 3.25), color: metal, parent: decor)
        box(SCNVector3(2.3, 0.06, 0.55), at: SCNVector3(-1.65, floor + 0.27, 3.25), color: charcoal, parent: decor)
        for x: Float in [-2.75, -0.55] { for z: Float in [2.99, 3.51] {
            box(SCNVector3(0.07, 0.82, 0.07), at: SCNVector3(x, floor + 0.41, z), color: metal, parent: decor)
        } }
        for index in 0..<5 {
            box(SCNVector3(0.47, 0.025, 0.61), at: SCNVector3(-2.63 + Float(index) * 0.49, floor + 0.905, 3.25),
                color: UIColor(red: 0.34, green: 0.25, blue: 0.18, alpha: 1), parent: decor)
        }
        for x: Float in [-2.24, -1.06] {
            box(SCNVector3(1.08, 0.24, 0.07), at: SCNVector3(x, floor + 0.66, 2.96), color: charcoal, parent: decor)
            box(SCNVector3(0.26, 0.035, 0.035), at: SCNVector3(x, floor + 0.68, 2.91), color: metal, parent: decor)
        }
        func cylinder(_ radius: CGFloat, _ height: CGFloat, _ position: SCNVector3, _ color: UIColor, forward: Bool = false) {
            let shape = SCNCylinder(radius: radius, height: height)
            shape.radialSegmentCount = 16; shape.heightSegmentCount = 1
            shape.firstMaterial = material(color)
            let node = SCNNode(geometry: shape); node.position = position
            if forward { node.eulerAngles.x = .pi / 2 }
            decor.addChildNode(node)
        }
        for (index, color) in colors.enumerated() {
            let x = -2.65 + Float(index % 4) * 0.23
            let z: Float = index < 4 ? 3.12 : 3.40
            cylinder(0.055, 0.24, SCNVector3(x, floor + 1.015, z), color.1)
            cylinder(0.039, 0.035, SCNVector3(x, floor + 1.15, z), charcoal)
            cylinder(0.056, 0.055, SCNVector3(x, floor + 1.015, z), UIColor(white: 0.87, alpha: 1))
            cylinder(0.056, 0.012, SCNVector3(x, floor + 0.91, z), metal)
            cylinder(0.056, 0.012, SCNVector3(x, floor + 1.13, z), metal)
            cylinder(0.012, 0.018, SCNVector3(x, floor + 1.174, z), .white)
            for stripe in 0..<3 {
                box(SCNVector3(0.032, 0.005, 0.004), at: SCNVector3(x, floor + 1.028 - Float(stripe) * 0.011, z - 0.056),
                    color: charcoal, parent: decor)
            }
        }
        // A small decorative radio, with two visible speaker cones.
        box(SCNVector3(0.60, 0.30, 0.20), at: SCNVector3(-0.93, floor + 1.04, 3.20), color: charcoal, parent: decor)
        for x: Float in [-1.11, -0.75] {
            cylinder(0.092, 0.025, SCNVector3(x, floor + 1.04, 3.09), metal, forward: true)
            cylinder(0.058, 0.03, SCNVector3(x, floor + 1.04, 3.07), .black, forward: true)
            for row in -2...2 {
                box(SCNVector3(0.13, 0.006, 0.008), at: SCNVector3(x, floor + 1.04 + Float(row) * 0.027, 3.049), color: charcoal, parent: decor)
            }
        }
        box(SCNVector3(0.09, 0.035, 0.01), at: SCNVector3(-0.93, floor + 1.12, 3.09), color: cyan, parent: decor)
        for x: Float in [-0.98, -0.88] {
            cylinder(0.021, 0.025, SCNVector3(x, floor + 0.96, 3.087), metal, forward: true)
            box(SCNVector3(0.006, 0.020, 0.006), at: SCNVector3(x, floor + 0.965, 3.071), color: .white, parent: decor)
        }
        cylinder(0.006, 0.36, SCNVector3(-0.69, floor + 1.36, 3.23), metal)
        for x: Float in [-1.06, -0.80] {
            box(SCNVector3(0.025, 0.10, 0.035), at: SCNVector3(x, floor + 1.24, 3.20), color: metal, parent: decor)
        }
        box(SCNVector3(0.285, 0.025, 0.035), at: SCNVector3(-0.93, floor + 1.29, 3.20), color: metal, parent: decor)
        for (x, z): (Float, Float) in [(0.60, 3.35), (1.30, 3.50)] {
            box(SCNVector3(0.55, 0.48, 0.55), at: SCNVector3(x, floor + 0.24, z), color: metal, parent: decor)
            box(SCNVector3(0.57, 0.035, 0.57), at: SCNVector3(x, floor + 0.50, z), color: charcoal, parent: decor)
            for offset: Float in [-0.21, 0.21] {
                box(SCNVector3(0.035, 0.48, 0.025), at: SCNVector3(x + offset, floor + 0.24, z - 0.28), color: charcoal, parent: decor)
            }
            for row in 1...4 {
                box(SCNVector3(0.48, 0.008, 0.008), at: SCNVector3(x, floor + Float(row) * 0.10, z - 0.279), color: charcoal, parent: decor)
            }
            box(SCNVector3(0.17, 0.045, 0.015), at: SCNVector3(x, floor + 0.40, z - 0.29), color: .black, parent: decor)
        }
        // Perforated tool board and brushes above the workbench.
        box(SCNVector3(2.25, 0.66, 0.035), at: SCNVector3(-1.65, 0.57, 3.92), color: metal, parent: decor)
        for column in 0..<9 { for row in 0..<4 {
            cylinder(0.012, 0.008, SCNVector3(-2.65 + Float(column) * 0.25, 0.33 + Float(row) * 0.15, 3.898), charcoal, forward: true)
        } }
        for (index, x) in [Float(-2.35), -1.98, -1.61].enumerated() {
            cylinder(0.016, 0.24, SCNVector3(x, 0.46, 3.855), colors[index].1)
            box(SCNVector3(0.045, 0.065, 0.03), at: SCNVector3(x, 0.60, 3.855), color: metal, parent: decor)
            box(SCNVector3(0.045, 0.08, 0.03), at: SCNVector3(x, 0.67, 3.855), color: UIColor(white: 0.76, alpha: 1), parent: decor)
        }
        // A skateboard resting in the rear corner, clear of the painting wall.
        box(SCNVector3(0.23, 0.81, 0.045), at: SCNVector3(1.93, floor + 0.47, 3.62), color: violet, parent: decor)
        box(SCNVector3(0.045, 0.65, 0.008), at: SCNVector3(1.93, floor + 0.47, 3.591), color: .white, parent: decor)
        for y in [floor + 0.19, floor + 0.75] {
            box(SCNVector3(0.31, 0.035, 0.035), at: SCNVector3(1.93, y, 3.58), color: metal, parent: decor)
            for x: Float in [1.79, 2.07] { cylinder(0.047, 0.04, SCNVector3(x, y, 3.55), charcoal, forward: true) }
        }
        let sign = CineText()
        sign.constraints = []; sign.setText("HANDAR  /  SPRAY LAB", color: cyan); sign.fitWidth(2.6)
        sign.position = SCNVector3(-1.65, 1.28, half - 0.05); sign.eulerAngles.y = .pi
        room.addChildNode(sign)
        box(SCNVector3(0.8, 0.55, 0.8), at: SCNVector3(2.8, floor + 0.275, 2.95), color: charcoal, parent: decor)
        let halo = SCNTorus(ringRadius: 0.42, pipeRadius: 0.013)
        halo.ringSegmentCount = 48; halo.pipeSegmentCount = 6; halo.firstMaterial = material(violet)
        let haloNode = SCNNode(geometry: halo)
        haloNode.position = SCNVector3(2.8, floor + 1.15, 2.95); haloNode.eulerAngles.x = .pi / 2
        decor.addChildNode(haloNode)
        var sharedMaterials: [UIColor: SCNMaterial] = [:]
        for node in decor.childNodes {
            guard let surface = node.geometry?.firstMaterial, let color = surface.diffuse.contents as? UIColor else { continue }
            if let shared = sharedMaterials[color] { node.geometry?.firstMaterial = shared }
            else { sharedMaterials[color] = surface }
        }
        let merged = decor.flattenedClone()
        room.addChildNode(merged)
        roomAccents.removeAll()
        var pending = [merged], seen = Set<ObjectIdentifier>()
        while let node = pending.popLast() {
            pending.append(contentsOf: node.childNodes)
            for surface in node.geometry?.materials ?? [] {
                guard let color = surface.diffuse.contents as? UIColor,
                      color == cyan || color == violet, seen.insert(ObjectIdentifier(surface)).inserted else { continue }
                roomAccents.append((surface, color == cyan))
            }
        }
        updateRoomMood()

        let cube = SCNBox(width: 0.32, height: 0.32, length: 0.32, chamferRadius: 0.035)
        sculptureMaterial.lightingModel = .constant
        cube.firstMaterial = sculptureMaterial
        let sculpture = SCNNode(geometry: cube)
        sculpture.position = haloNode.position
        sculpture.runAction(.repeatForever(.rotateBy(x: 0.5, y: .pi * 2, z: 0.3, duration: 14)))
        room.addChildNode(sculpture)
    }

    func start(in scene: SCNScene, head: SCNNode) {
        stop()
        isRunning = true; aligned = false; mode = .room
        sprayGate = GraffitiSprayGate(); colorIndex = 0; sizeIndex = 1
        rainbow = false; mood = .neon
        root.simdTransform = matrix_identity_float4x4
        scene.rootNode.addChildNode(root)
        room.isHidden = false; home.isHidden = true; ui.isHidden = false
        recenterControls(head: head)
        setPalette(false); updateSelection(); setHint("Готовим AR 1×…")
    }

    func align(head: SCNNode) {
        guard isRunning, !aligned else { return }
        aligned = true
        let t = head.simdWorldTransform
        let yaw = PanoramaProjection.yaw(forward: SIMD3(-t.columns.2.x, 0, -t.columns.2.z))
        room.simdPosition = head.simdWorldPosition
        room.eulerAngles.y = yaw
        let half = GraffitiRoomLayout.span * 0.5
        for index in 0..<4 {
            let size = SIMD2(Double(GraffitiRoomLayout.span), Double(GraffitiRoomLayout.wallHeight))
            let canvas = GraffitiCanvas(size: size, base: UIColor(white: 0.80 - CGFloat(index) * 0.025, alpha: 1), textureWidth: 1536)
            let angle = Float(index) * .pi / 2
            canvas.node.position = SCNVector3(-sin(angle) * half, GraffitiRoomLayout.wallCenterY, -cos(angle) * half)
            canvas.node.eulerAngles.y = angle
            room.addChildNode(canvas.node); roomCanvases.append(canvas)
        }
        buildRoomDecor()
        recenterControls(head: head)
        setHint("Открой ладонь — рисовать · «Цвет» — палитра")
    }

    func recenterControls(head: SCNNode) {
        guard isRunning else { return }
        let t = head.simdWorldTransform
        ui.simdWorldPosition = head.simdWorldPosition
        ui.eulerAngles.y = PanoramaProjection.yaw(forward: SIMD3(-t.columns.2.x, 0, -t.columns.2.z))
        ui.isHidden = false
        cancelInput()
    }

    func stop() {
        cancelInput()
        for anchor in paintAnchors { onRemoveAnchor?(anchor) }
        paintAnchors.removeAll()
        canvasAnchors.removeAll(); homeCanvases.removeAll(); roomCanvases.removeAll(); undo.removeAll()
        roomAccents.removeAll()
        for child in room.childNodes { child.removeFromParentNode() }
        for child in home.childNodes { child.removeFromParentNode() }
        root.removeFromParentNode(); isRunning = false; aligned = false
    }

    func update(anchor: ARAnchor) {
        canvasAnchors[anchor.identifier]?.node.simdWorldTransform = anchor.transform
    }

    private func setHint(_ value: String) {
        guard hint != value else { return }; hint = value
        status.setText(value); status.fitWidth(1.35)
    }

    private func endStroke() { activeCanvas = nil; sampler.reset(); mist.isHidden = true; paintingHand = nil }

    private func stopSpraying() {
        sprayGate.cancel(); endStroke(); can.isHidden = true; aim.isHidden = true
    }

    func cancelInput() {
        stopSpraying(); uiGate.cancel(); ring.isHidden = true
        uiHand = nil; uiBlocked = false
    }

    func tick(at time: Double, trackingReady: Bool) {
        guard isRunning else { return }
        if !trackingReady || time - lastHandAt > 0.2 {
            if paintingHand != nil { setHint("Покажи открытую ладонь, чтобы продолжить") }
            stopSpraying()
        }
        if !trackingReady { uiGate.cancel(); ring.isHidden = true; setHint("Ожидаю устойчивое отслеживание камеры…") }
        if time - lastUpload >= 1.0 / 15 {
            for canvas in roomCanvases + homeCanvases where canvas.dirty { canvas.upload() }
            lastUpload = time
        }
    }

    /// Controls consume the palm ray before it can paint through the panel.
    func updateUI(ray: WorldRay?, hand: TrackedHand? = nil, at time: Double) -> Bool {
        guard isRunning, aligned else { return false }
        if uiHand != hand { uiGate.cancel(); uiHand = hand }
        let available = [("palette", paletteButton)] + (paletteOpen ? buttons : [])
        let target = ray.flatMap { ray in available.first { $0.1.hitTest(ray: ray) } }
        for (_, button) in available { button.setHighlight(button === target?.1) }
        let action = uiGate.update(target: target?.0, down: false, allowBegin: false, dwell: true, at: time)
        ring.show(on: target?.1.node, progress: uiGate.dwellProgress)
        if let action, perform(action) { onInteraction?() }
        uiBlocked = target != nil || paletteOpen
        if uiBlocked { endStroke(); can.isHidden = true; aim.isHidden = true }
        return uiBlocked
    }

    func updateHand(hand: TrackedHand?, open: Bool, ray: WorldRay?, distance: Float, toolOffset: SIMD3<Float>,
                    blocked: Bool, trackingReady: Bool, at time: Double) {
        guard isRunning, aligned else { return }
        let spraying = sprayGate.update(hand: hand, open: open, reliable: trackingReady && ray != nil,
                                        blocked: blocked || uiBlocked || paletteOpen, at: time)
        guard let ray, trackingReady, hand != nil else {
            endStroke(); can.isHidden = true; aim.isHidden = true
            if trackingReady, !paletteOpen { setHint("Открой ладонь — рисовать · «Цвет» — палитра") }
            return
        }
        lastHandAt = time
        can.isHidden = !sprayGate.canVisible
        can.simdWorldPosition = ray.point(at: distance) + toolOffset
        can.look(at: SCNVector3(ray.point(at: distance + 1)), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        guard spraying else {
            endStroke(); aim.isHidden = true
            if !paletteOpen {
                setHint(open ? "Уведи ладонь от кнопок к стене" : "Открой ладонь — рисовать · «Цвет» — палитра")
            }
            return
        }
        guard let hit = paintHit(ray: ray) else {
            endStroke(); aim.isHidden = true
            setHint(mode == .home ? (homeCanvases.count >= 12 ? "Лимит холстов сеанса · рисуй на уже начатой стене" : "Осмотри стену камерой, чтобы найти поверхность") : "Направь ладонь на стену")
            return
        }
        aim.isHidden = false
        aim.simdWorldTransform = hit.canvas.node.simdWorldTransform
        let marker = hit.canvas.node.convertPosition(SCNVector3(Float(hit.point.x), Float(hit.point.y), 0.008), to: root)
        aim.simdPosition = SIMD3(marker.x, marker.y, marker.z)
        can.look(at: marker, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        // The small ring geometry lies in XZ; rotate its own mesh into the wall's XY.
        aim.simdWorldOrientation = hit.canvas.node.simdWorldOrientation * simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        if activeCanvas != hit.canvas.id {
            endStroke()
            guard let image = hit.canvas.snapshot() else { setHint("Не удалось создать холст"); return }
            activeCanvas = hit.canvas.id
            undo.append((hit.canvas.id, image)); if undo.count > 6 { undo.removeFirst() }
        }
        let points = sampler.points(to: hit.point, radius: radii[sizeIndex], at: time)
        paintingHand = hand
        let color = paintColor(at: time)
        canMaterial.diffuse.contents = color
        sculptureMaterial.diffuse.contents = color
        mist.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.16)
        hit.canvas.spray(points: points, radius: radii[sizeIndex], color: color, clip: hit.clip)
        mist.isHidden = false
        setHint("\(rainbow ? "Радуга" : colors[colorIndex].0) · убери или закрой ладонь — стоп")
    }

    private struct Hit { let canvas: GraffitiCanvas; let point: SIMD2<Double>; let clip: [SIMD2<Double>]? }

    private func paintHit(ray: WorldRay) -> Hit? {
        if mode == .room {
            var best: (Float, Hit)?
            for canvas in roomCanvases {
                let inverse = canvas.node.simdWorldTransform.inverse
                let origin = inverse * SIMD4(ray.origin, 1), direction = inverse * SIMD4(ray.direction, 0)
                guard abs(direction.z) > 0.001 else { continue }
                let t = -origin.z / direction.z
                guard t > 0.15, t < GraffitiRoomLayout.maximumPaintDistance else { continue }
                let p = origin + direction * t, point = SIMD2(Double(p.x), Double(p.y))
                guard GraffitiGeometry.uv(point: point, size: canvas.size) != nil else { continue }
                if best == nil || t < best!.0 { best = (t, Hit(canvas: canvas, point: point, clip: nil)) }
            }
            return best?.1
        }
        guard let result = wallHit?(ray), let anchor = result.anchor as? ARPlaneAnchor else { return nil }
        let vertices = anchor.geometry.boundaryVertices
        guard vertices.count >= 3 else { return nil }
        let p = result.worldTransform.columns.3
        let world = SIMD3(p.x, p.y, p.z)
        let distance = simd_length(world - ray.origin)
        guard distance > 0.2, distance < 6 else { return nil }
        let normal = SIMD3(anchor.transform.columns.1.x, anchor.transform.columns.1.y, anchor.transform.columns.1.z)
        // Reuse metric canvases by world position, also after ARKit merges plane anchors.
        var canvas = homeCanvases.first { surface in
            let local = surface.node.simdWorldTransform.inverse * SIMD4(world, 1)
            let z = surface.node.simdWorldTransform.columns.2
            return abs(local.z) < 0.06 && abs(simd_dot(SIMD3(z.x, z.y, z.z), normal)) > 0.98 &&
                GraffitiGeometry.uv(point: SIMD2(Double(local.x), Double(local.y)), size: surface.size) != nil
        }
        if canvas == nil {
            guard homeCanvases.count < 12 else { setHint("Достигнут лимит стен этого сеанса"); return nil }
            let new = GraffitiCanvas(size: SIMD2(2, 2), base: .clear)
            home.addChildNode(new.node)
            var transform = anchor.transform * simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0)))
            let facing: Float = simd_dot(normal, ray.origin - world) >= 0 ? 1 : -1
            transform.columns.3 = SIMD4(world + normal * (0.004 * facing), 1)
            new.node.simdWorldTransform = transform
            let paintAnchor = ARAnchor(name: "HandAR-graffiti", transform: transform)
            canvasAnchors[paintAnchor.identifier] = new; paintAnchors.append(paintAnchor); homeCanvases.append(new)
            onAddAnchor?(paintAnchor); canvas = new
        }
        guard let canvas else { return nil }
        let inverse = canvas.node.simdWorldTransform.inverse
        let local = inverse * SIMD4(world, 1)
        let boundary = vertices.map { vertex -> SIMD2<Double> in
            let p = inverse * anchor.transform * SIMD4(vertex, 1)
            return SIMD2(Double(p.x), Double(p.y))
        }
        return Hit(canvas: canvas, point: SIMD2(Double(local.x), Double(local.y)), clip: boundary)
    }

    private func setPalette(_ open: Bool) {
        paletteOpen = open; panel.isHidden = !open
        paletteButton.setTitle(open ? "Готово" : "Цвет")
        setHint(open ? "Рисунки этого сеанса удалятся при выходе в меню" : "Открой ладонь — рисовать · «Цвет» — палитра")
        stopSpraying()
        // Keep the dwell latch until the pointer leaves the toggle button.
    }

    private func updateSelection() {
        canMaterial.diffuse.contents = colors[colorIndex].1
        sculptureMaterial.diffuse.contents = colors[colorIndex].1
        mist.geometry?.firstMaterial?.diffuse.contents = colors[colorIndex].1.withAlphaComponent(0.16)
        for (id, button) in buttons {
            if id.hasPrefix("color-"), let n = Int(id.dropFirst(6)) { button.setTitle((n == colorIndex ? "✓ " : "") + colors[n].0) }
            if id.hasPrefix("size-"), let n = Int(id.dropFirst(5)) { button.setTitle((n == sizeIndex ? "✓ " : "") + ["Тонко", "Средне", "Широко"][n]) }
            if id == "room" { button.setTitle(mode == .room ? "✓ Комната" : "Комната") }
            if id == "home" { button.setTitle(mode == .home ? "✓ Мои стены" : "Мои стены") }
            if id == "rainbow" { button.setTitle(rainbow ? "Радуга: вкл" : "Радуга: выкл") }
            if id == "mood" { button.setTitle("Свет: \(mood.title)") }
        }
    }

    private func paintColor(at time: Double) -> UIColor {
        guard rainbow, time.isFinite else { return colors[colorIndex].1 }
        let hue = (time * 0.12).truncatingRemainder(dividingBy: 1)
        return UIColor(hue: CGFloat(hue < 0 ? hue + 1 : hue), saturation: 0.85, brightness: 1, alpha: 1)
    }

    private func updateRoomMood() {
        let pair: (UIColor, UIColor)
        switch mood {
        case .neon:
            pair = (UIColor(red: 0.18, green: 0.79, blue: 0.90, alpha: 1), UIColor(red: 0.69, green: 0.38, blue: 0.91, alpha: 1))
        case .sunset:
            pair = (UIColor(red: 1, green: 0.58, blue: 0.22, alpha: 1), UIColor(red: 0.96, green: 0.26, blue: 0.44, alpha: 1))
        case .mint:
            pair = (UIColor(red: 0.24, green: 0.92, blue: 0.65, alpha: 1), UIColor(red: 0.24, green: 0.61, blue: 0.98, alpha: 1))
        }
        for (surface, left) in roomAccents { surface.diffuse.contents = left ? pair.0 : pair.1 }
    }

    private func perform(_ action: String) -> Bool {
        if action == "palette" { setPalette(!paletteOpen); return true }
        stopSpraying()
        if action.hasPrefix("color-"), let n = Int(action.dropFirst(6)), colors.indices.contains(n) { colorIndex = n; rainbow = false }
        if action == "rainbow" { rainbow.toggle() }
        if action == "mood" { mood = mood.next; updateRoomMood() }
        if action.hasPrefix("size-"), let n = Int(action.dropFirst(5)), radii.indices.contains(n) { sizeIndex = n }
        if action == "room" || action == "home" {
            mode = action == "room" ? .room : .home
            room.isHidden = mode != .room; home.isHidden = mode != .home
            onModeChanged?(mode)
            setHint(mode == .home ? "Осмотри стену камерой · закрой палитру" : "Закрой палитру и покажи ладонь")
        }
        let visibleCanvases = mode == .room ? roomCanvases : homeCanvases
        if action == "undo", let index = undo.lastIndex(where: { entry in visibleCanvases.contains { $0.id == entry.0 } }) {
            let entry = undo.remove(at: index)
            if let canvas = visibleCanvases.first(where: { $0.id == entry.0 }) { canvas.restore(entry.1); canvas.upload() }
        }
        if action == "exit" { onExit?() }
        updateSelection()
        return true
    }
}
