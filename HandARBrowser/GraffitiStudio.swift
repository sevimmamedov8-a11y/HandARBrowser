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

    func spray(points: [SIMD2<Double>], radius: Double, color: UIColor, clip: [SIMD2<Double>]?, flow: Double, hardEdge: Bool, erasing: Bool = false) {
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
        if erasing {
            // Replace pixels with the original wall, including transparent
            // pixels in passthrough mode. Painting white would obscure the room.
            context.setBlendMode(.copy); context.setFillColor(base.cgColor)
            let r = CGFloat(radius*scale)
            for point in points {
                let center = pixel(point)
                context.fillEllipse(in: CGRect(x:center.x-r,y:center.y-r,width:2*r,height:2*r))
            }
            context.restoreGState(); dirty = true; return
        }
        let colors = [color.withAlphaComponent(CGFloat(0.28*flow)).cgColor, color.withAlphaComponent(CGFloat((hardEdge ? 0.25 : 0.10)*flow)).cgColor,
                      color.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, hardEdge ? 0.88 : 0.55, 1]) {
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
    private let props = GraffitiProps(), floorGrid = SCNNode()
    private let audio = GraffitiAudio()
    private var roomSculpture: SCNNode?
    private var preferences = GraffitiPreferences.load()
    private var settingsPage = false
    private var radioPage = false
    private let radio = GraffitiRadio()
    private let radioStatus = CineText()
    private let radioButton = CineButton(title: "▶", color: .darkGray, width: 0.22, height: 0.10)
    private var radioNode: SCNNode?
    private var roomAccents: [(SCNMaterial, Bool)] = []
    private var mood = GraffitiRoomMood.neon
    private var rainbow = false
    private var erasing = false
    private var brushRadius: Double { radii[sizeIndex] * (erasing ? 2 : 1) }
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
    var onImportMusic: (() -> Void)?
    func importMusic(_ urls: [URL]) { radio.importSongs(urls) }
    var onModeChanged: ((GraffitiMode) -> Void)?
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
        radio.onChange = { [weak self] in self?.updateRadioControls() }
        props.onPickColor = { [weak self] color in
            guard let self else { return }
            self.colorIndex = color; self.rainbow = false; self.erasing = false; self.updateSelection()
        }
        props.onHint = { [weak self] text in self?.setHint(text) }
        props.onInteraction = { [weak self] sound, intensity in self?.audio.play(sound, intensity: intensity) }
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
        box(SCNVector3(1.12, 1.38, 0.035), at: SCNVector3(0, -0.04, -1.36),
            color: UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.97), parent: panel)
        func button(_ id: String, _ title: String, _ x: Float, _ y: Float, _ color: UIColor = .darkGray, width: Float = 0.25) {
            let b = CineButton(title: title, color: color, width: width, height: 0.14)
            b.node.position = SCNVector3(x, y, -1.32); panel.addChildNode(b.node); buttons.append((id, b))
        }
        button("tab-paint", "Краска", -0.35, 0.53, width: 0.32)
        button("tab-settings", "Настройки", 0, 0.53, width: 0.32)
        button("tab-radio", "Радио", 0.35, 0.53, width: 0.32)
        for (index, entry) in [("radio-toggle", "Включить"), ("radio-next", "Следующая"),
            ("radio-volume", "Громкость: 40%"), ("radio-import", "Добавить песни"),
            ("radio-own", "Мои песни"), ("radio-default", "Спокойная музыка"), ("radio-close", "Закрыть")].enumerated() {
            button(entry.0, entry.1, index % 2 == 0 ? -0.27 : 0.27, 0.32-Float(index/2)*0.19, width: 0.49)
        }
        radioStatus.constraints = []
        radioStatus.position = SCNVector3(0, -0.48, -1.30); panel.addChildNode(radioStatus)
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
        button("eraser", "Стиралка", -0.35, -0.56, width: 0.32)
        button("undo", "Отменить", 0, -0.56, width: 0.32)
        button("exit", "В меню", 0.35, -0.56, width: 0.32)
        for (index, entry) in [
            ("setting-paint", "Краска: вкл"), ("setting-grab", "Захват: вкл"),
            ("setting-flow", "Слой: обычный"), ("setting-edge", "Край: мягкий"),
            ("setting-light", "Яркость: средняя"), ("setting-grid", "Сетка: вкл"),
            ("setting-animation", "Куб: вращается"), ("setting-props", "Вернуть вещи"),
            ("setting-reset", "Сброс настроек"), ("setting-close", "Закрыть"),
            ("setting-sound", "Звук: вкл"), ("setting-volume", "Громкость: 55%")].enumerated() {
            button(entry.0, entry.1, index % 2 == 0 ? -0.27 : 0.27, 0.32-Float(index/2)*0.19, width: 0.49)
        }
        panel.isHidden = true
    }

    private func buildRoomDecor() {
        // Architecture is merged once; pickable objects keep independent roots.
        let decor = SCNNode()
        props.clear()
        // Broad diffuse light adds shape without costly dynamic shadows.
        let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 420; ambient.categoryBitMask = 1
        let ambientNode = SCNNode(); ambientNode.light = ambient; room.addChildNode(ambientNode)
        let key = SCNLight(); key.type = .directional; key.intensity = 850; key.categoryBitMask = 1
        key.color = UIColor(red: 1, green: 0.94, blue: 0.85, alpha: 1); key.castsShadow = false
        let keyNode = SCNNode(); keyNode.light = key; keyNode.eulerAngles = SCNVector3(-0.8, -0.5, 0)
        room.addChildNode(keyNode)
        for child in floorGrid.childNodes { child.removeFromParentNode() }
        let grid = SCNNode()
        let span = GraffitiRoomLayout.span, half = span * 0.5
        let floor = GraffitiRoomLayout.floorY, ceiling = GraffitiRoomLayout.ceilingY
        let rear = half - 4
        let charcoal = UIColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        let metal = UIColor(red: 0.26, green: 0.30, blue: 0.36, alpha: 1)
        let cyan = UIColor(red: 0.18, green: 0.79, blue: 0.90, alpha: 1)
        let violet = UIColor(red: 0.69, green: 0.38, blue: 0.91, alpha: 1)
        box(SCNVector3(span + 0.05, 0.05, span + 0.05), at: SCNVector3(0, floor, 0), color: charcoal, parent: decor)
        box(SCNVector3(span + 0.05, 0.05, span + 0.05), at: SCNVector3(0, ceiling, 0), color: UIColor(white: 0.09, alpha: 1), parent: decor)
        for offset in -5...5 {
            let line = UIColor(white: 0.19, alpha: 1)
            box(SCNVector3(0.012, 0.004, span), at: SCNVector3(Float(offset), floor + 0.027, 0), color: line, parent: grid)
            box(SCNVector3(span, 0.004, 0.012), at: SCNVector3(0, floor + 0.027, Float(offset)), color: line, parent: grid)
        }
        let gridMaterial = material(UIColor(white: 0.19, alpha: 1))
        for node in grid.childNodes { node.geometry?.firstMaterial = gridMaterial }
        floorGrid.addChildNode(grid.flattenedClone()); room.addChildNode(floorGrid)
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
        box(SCNVector3(2.5, 0.09, 0.65), at: SCNVector3(-1.65, floor + 0.85, (rear + 3.25)), color: metal, parent: decor)
        box(SCNVector3(2.3, 0.06, 0.55), at: SCNVector3(-1.65, floor + 0.27, (rear + 3.25)), color: charcoal, parent: decor)
        for x: Float in [-2.75, -0.55] { for z: Float in [(rear + 2.99), (rear + 3.51)] {
            box(SCNVector3(0.07, 0.82, 0.07), at: SCNVector3(x, floor + 0.41, z), color: metal, parent: decor)
        } }
        for index in 0..<5 {
            box(SCNVector3(0.47, 0.025, 0.61), at: SCNVector3(-2.63 + Float(index) * 0.49, floor + 0.905, (rear + 3.25)),
                color: UIColor(red: 0.34, green: 0.25, blue: 0.18, alpha: 1), parent: decor)
        }
        for x: Float in [-2.24, -1.06] {
            box(SCNVector3(1.08, 0.24, 0.07), at: SCNVector3(x, floor + 0.66, (rear + 2.96)), color: charcoal, parent: decor)
            box(SCNVector3(0.26, 0.035, 0.035), at: SCNVector3(x, floor + 0.68, (rear + 2.91)), color: metal, parent: decor)
        }
        func cylinder(_ radius: CGFloat, _ height: CGFloat, _ position: SCNVector3, _ color: UIColor, forward: Bool = false) {
            let shape = SCNCylinder(radius: radius, height: height)
            shape.radialSegmentCount = 16; shape.heightSegmentCount = 1
            shape.firstMaterial = material(color)
            let node = SCNNode(geometry: shape); node.position = position
            if forward { node.eulerAngles.x = .pi / 2 }
            decor.addChildNode(node)
        }
        @discardableResult
        func movable(_ start: Int, _ name: String, _ center: SCNVector3, _ halfSize: SIMD3<Float>, color: Int? = nil, sound: GraffitiSound = .wood) -> SCNNode {
            let parts = Array(decor.childNodes.dropFirst(start))
            for part in parts { part.geometry?.firstMaterial?.lightingModel = .lambert }
            return props.add(parts: parts, name: name, center: center, halfSize: halfSize, color: color, sound: sound, in: room)
        }
        // Fine grain in the five wooden worktop boards, flattened with the bench.
        for board in 0..<5 { for line in 0..<7 {
            box(SCNVector3(0.003, 0.001, 0.48-Float(line%3)*0.06),
                at: SCNVector3(-2.82+Float(board)*0.49+Float(line)*0.06, floor+0.919, rear+3.25),
                color: UIColor(red: 0.26, green: 0.18, blue: 0.12, alpha: 1), parent: decor)
        } }
        for (index, color) in colors.enumerated() {
            let start = decor.childNodes.count
            let x = -2.65 + Float(index % 4) * 0.23
            let z: Float = index < 4 ? (rear + 3.12) : (rear + 3.40)
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
            for stripe in 0..<6 {
                box(SCNVector3(0.002, 0.022, 0.002), at: SCNVector3(x-0.015+Float(stripe)*0.005, floor+1.015, z+0.057),
                    color: charcoal, parent: decor)
            }
            movable(start, "Баллончик: \(color.0)", SCNVector3(x, floor + 1.045, z), SIMD3(0.058, 0.14, 0.06), color: index, sound: .metal)
        }
        // Working portable radio. Its playback button moves with the object.
        let radioStart = decor.childNodes.count
        box(SCNVector3(0.60, 0.30, 0.20), at: SCNVector3(-0.93, floor + 1.04, (rear + 3.20)), color: charcoal, parent: decor)
        for x: Float in [-1.11, -0.75] {
            cylinder(0.092, 0.025, SCNVector3(x, floor + 1.04, (rear + 3.09)), metal, forward: true)
            cylinder(0.058, 0.03, SCNVector3(x, floor + 1.04, (rear + 3.07)), .black, forward: true)
            for row in -2...2 {
                box(SCNVector3(0.13, 0.006, 0.008), at: SCNVector3(x, floor + 1.04 + Float(row) * 0.027, (rear + 3.049)), color: charcoal, parent: decor)
            }
        }
        box(SCNVector3(0.09, 0.035, 0.01), at: SCNVector3(-0.93, floor + 1.12, (rear + 3.09)), color: cyan, parent: decor)
        for x: Float in [-0.98, -0.88] {
            cylinder(0.021, 0.025, SCNVector3(x, floor + 0.96, (rear + 3.087)), metal, forward: true)
            box(SCNVector3(0.006, 0.020, 0.006), at: SCNVector3(x, floor + 0.965, (rear + 3.071)), color: .white, parent: decor)
        }
        cylinder(0.006, 0.36, SCNVector3(-0.69, floor + 1.36, (rear + 3.23)), metal)
        for x: Float in [-1.06, -0.80] {
            box(SCNVector3(0.025, 0.10, 0.035), at: SCNVector3(x, floor + 1.24, (rear + 3.20)), color: metal, parent: decor)
        }
        box(SCNVector3(0.285, 0.025, 0.035), at: SCNVector3(-0.93, floor + 1.29, (rear + 3.20)), color: metal, parent: decor)
        for x: Float in [-1.19, -0.67] {
            for y in [floor+0.93, floor+1.16] {
                cylinder(0.008, 0.006, SCNVector3(x,y,rear+3.095), metal, forward: true)
            }
            box(SCNVector3(0.07,0.025,0.14), at: SCNVector3(x,floor+0.878,rear+3.20), color: .black, parent: decor)
        }
        for mark in 0..<7 {
            box(SCNVector3(0.003,0.015,0.003), at: SCNVector3(-0.963+Float(mark)*0.011,floor+1.12,rear+3.083),
                color: charcoal, parent: decor)
        }
        radioNode = movable(radioStart, "Радио", SCNVector3(-0.93, floor + 1.21, rear + 3.20), SIMD3(0.31, 0.34, 0.15), sound: .plastic)
        radioButton.node.position = SCNVector3(0, -0.17, -0.16)
        radioButton.node.eulerAngles.y = .pi
        radioNode?.addChildNode(radioButton.node)
        for (x, z): (Float, Float) in [(0.60, (rear + 3.35)), (1.30, (rear + 3.50))] {
            let start = decor.childNodes.count
            box(SCNVector3(0.55, 0.48, 0.55), at: SCNVector3(x, floor + 0.24, z), color: metal, parent: decor)
            box(SCNVector3(0.57, 0.035, 0.57), at: SCNVector3(x, floor + 0.50, z), color: charcoal, parent: decor)
            for offset: Float in [-0.21, 0.21] {
                box(SCNVector3(0.035, 0.48, 0.025), at: SCNVector3(x + offset, floor + 0.24, z - 0.28), color: charcoal, parent: decor)
            }
            for row in 1...4 {
                box(SCNVector3(0.48, 0.008, 0.008), at: SCNVector3(x, floor + Float(row) * 0.10, z - 0.279), color: charcoal, parent: decor)
            }
            box(SCNVector3(0.17, 0.045, 0.015), at: SCNVector3(x, floor + 0.40, z - 0.29), color: .black, parent: decor)
            for side: Float in [-1,1] {
                for y in [floor+0.07,floor+0.43] {
                    cylinder(0.01,0.008,SCNVector3(x+side*0.21,y,z-0.298),metal,forward:true)
                }
                for row in 1...4 {
                    box(SCNVector3(0.008,0.008,0.48),at:SCNVector3(x+side*0.279,floor+Float(row)*0.10,z),color:charcoal,parent:decor)
                }
            }
            movable(start, "Ящик", SCNVector3(x, floor + 0.26, z), SIMD3(0.285, 0.26, 0.30))
        }
        // Perforated tool board and brushes above the workbench.
        box(SCNVector3(2.25, 0.66, 0.035), at: SCNVector3(-1.65, 0.57, (rear + 3.92)), color: metal, parent: decor)
        for column in 0..<9 { for row in 0..<4 {
            cylinder(0.012, 0.008, SCNVector3(-2.65 + Float(column) * 0.25, 0.33 + Float(row) * 0.15, (rear + 3.898)), charcoal, forward: true)
        } }
        for (index, x) in [Float(-2.35), -1.98, -1.61].enumerated() {
            let start = decor.childNodes.count
            cylinder(0.016, 0.24, SCNVector3(x, 0.46, (rear + 3.855)), colors[index].1)
            box(SCNVector3(0.045, 0.065, 0.03), at: SCNVector3(x, 0.60, (rear + 3.855)), color: metal, parent: decor)
            box(SCNVector3(0.045, 0.08, 0.03), at: SCNVector3(x, 0.67, (rear + 3.855)), color: UIColor(white: 0.76, alpha: 1), parent: decor)
            movable(start, "Кисть", SCNVector3(x, 0.525, rear + 3.855), SIMD3(0.024, 0.19, 0.018), sound: .soft)
        }
        // A skateboard resting in the rear corner, clear of the painting wall.
        let skateStart = decor.childNodes.count
        box(SCNVector3(0.23, 0.81, 0.045), at: SCNVector3(1.93, floor + 0.47, (rear + 3.62)), color: violet, parent: decor)
        box(SCNVector3(0.045, 0.65, 0.008), at: SCNVector3(1.93, floor + 0.47, (rear + 3.591)), color: .white, parent: decor)
        for y in [floor + 0.19, floor + 0.75] {
            box(SCNVector3(0.31, 0.035, 0.035), at: SCNVector3(1.93, y, (rear + 3.58)), color: metal, parent: decor)
            for x: Float in [1.79, 2.07] {
                cylinder(0.047,0.04,SCNVector3(x,y,rear+3.55),charcoal,forward:true)
                cylinder(0.018,0.045,SCNVector3(x,y,rear+3.54),metal,forward:true)
                cylinder(0.007,0.05,SCNVector3(x,y,rear+3.535),.black,forward:true)
            }
            for dx: Float in [-0.055,0.055] { for dy: Float in [-0.025,0.025] {
                cylinder(0.006,0.008,SCNVector3(1.93+dx,y+dy,rear+3.588),metal,forward:true)
            } }
        }
        movable(skateStart, "Скейт", SCNVector3(1.93, floor + 0.47, rear + 3.59), SIMD3(0.18, 0.41, 0.07))
        // A grabbable football with raised curved pentagonal panels.
        let ballStart = decor.childNodes.count
        let ballCenter = SCNVector3(1.1, floor+0.139, 3.5)
        let sphere = SCNSphere(radius:0.11); sphere.segmentCount = 24
        sphere.firstMaterial = material(UIColor(white:0.92,alpha:1))
        let ballBody = SCNNode(geometry:sphere); ballBody.position = ballCenter; decor.addChildNode(ballBody)
        let patches = GraffitiFootball.patches()
        let vertices = patches.vertices.map { SCNVector3($0.x*0.11,$0.y*0.11,$0.z*0.11) }
        let element = SCNGeometryElement(indices:patches.indices,primitiveType:.triangles)
        let normals = patches.vertices.map { SCNVector3($0.x/1.006,$0.y/1.006,$0.z/1.006) }
        let panels = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),SCNGeometrySource(normals:normals)],elements:[element])
        panels.firstMaterial = material(charcoal)
        let ballPanels = SCNNode(geometry:panels); ballPanels.position = ballCenter; decor.addChildNode(ballPanels)
        for part in decor.childNodes.dropFirst(ballStart) { part.geometry?.firstMaterial?.lightingModel = .lambert }
        props.add(parts:Array(decor.childNodes.dropFirst(ballStart)),name:"Футбольный мяч",center:ballCenter,
            halfSize:SIMD3(repeating:0.111),sound:.rubber,ball:true,in:room)
        let sign = CineText()
        sign.constraints = []; sign.setText("HANDAR  /  SPRAY LAB", color: cyan); sign.fitWidth(2.6)
        sign.position = SCNVector3(-1.65, 1.28, half - 0.05); sign.eulerAngles.y = .pi
        room.addChildNode(sign)
        box(SCNVector3(0.8, 0.55, 0.8), at: SCNVector3(2.8, floor + 0.275, (rear + 2.95)), color: charcoal, parent: decor)
        let halo = SCNTorus(ringRadius: 0.42, pipeRadius: 0.013)
        halo.ringSegmentCount = 48; halo.pipeSegmentCount = 6; halo.firstMaterial = material(violet)
        let haloNode = SCNNode(geometry: halo)
        haloNode.position = SCNVector3(2.8, floor + 1.15, (rear + 2.95)); haloNode.eulerAngles.x = .pi / 2
        decor.addChildNode(haloNode)
        // High roof beams and wall bays frame the studio without covering the
        // central front canvas. All of this remains static, shared geometry.
        for z: Float in [-3, 0, 3] {
            box(SCNVector3(span-0.3, 0.12, 0.15), at: SCNVector3(0, ceiling-0.24, z), color: metal, parent: decor)
            box(SCNVector3(3.8, 0.015, 0.06), at: SCNVector3(0, ceiling-0.31, z), color: cyan, parent: decor)
        }
        for side: Float in [-1, 1] {
            for z: Float in [-2.6, 0, 2.6] {
                box(SCNVector3(0.075, 2.7, 1.3), at: SCNVector3(side*(half-0.12), 0.65, z), color: charcoal, parent: decor)
                for rib in 0..<6 {
                    box(SCNVector3(0.025, 2.55, 0.025), at: SCNVector3(side*(half-0.17), 0.65, z-0.5+Float(rib)*0.2),
                        color: metal, parent: decor)
                }
                box(SCNVector3(0.035, 0.035, 1.3), at: SCNVector3(side*(half-0.17), 2.04, z),
                    color: side < 0 ? cyan : violet, parent: decor)
            }
        }
        // A raised lounge with upholstered cushions beside the rear wall.
        let fabric = UIColor(red: 0.19, green: 0.30, blue: 0.34, alpha: 1)
        box(SCNVector3(1.5, 0.18, 2.5), at: SCNVector3(4.7, floor+0.09, 3.45), color: metal, parent: decor)
        box(SCNVector3(0.18, 1.1, 2.15), at: SCNVector3(5.18, floor+0.73, 3.45), color: charcoal, parent: decor)
        for z: Float in [2.75, 3.45, 4.15] {
            box(SCNVector3(0.94, 0.24, 0.65), at: SCNVector3(4.68, floor+0.46, z), color: fabric, parent: decor)
            box(SCNVector3(0.20, 0.59, 0.65), at: SCNVector3(5.05, floor+0.85, z), color: fabric, parent: decor)
        }
        for z: Float in [2.75,3.45,4.15] {
            for edge: Float in [-0.30,0.30] {
                box(SCNVector3(0.88,0.007,0.007),at:SCNVector3(4.68,floor+0.583,z+edge),color:metal,parent:decor)
            }
            for x: Float in [4.24,5.12] {
                box(SCNVector3(0.007,0.007,0.60),at:SCNVector3(x,floor+0.583,z),color:metal,parent:decor)
            }
        }
        // Planters: separate stems and angled leaf blades, with no animation.
        for x: Float in [-4.8, 4.8] {
            cylinder(0.24, 0.43, SCNVector3(x, floor+0.245, 5.15), metal)
            cylinder(0.215, 0.025, SCNVector3(x, floor+0.465, 5.15), UIColor(white: 0.12, alpha: 1))
            for leaf in 0..<7 {
                let angle = Float(leaf)*0.90
                let dx = cos(angle)*0.19, dz = sin(angle)*0.19
                box(SCNVector3(0.018, 0.72, 0.018), at: SCNVector3(x+dx*0.4, floor+0.80, 5.15+dz*0.4),
                    color: UIColor(red: 0.25, green: 0.36, blue: 0.22, alpha: 1), parent: decor)
                let blade = SCNSphere(radius: 1); blade.segmentCount = 12
                blade.firstMaterial = material(UIColor(red: 0.23, green: 0.46, blue: 0.34, alpha: 1))
                let leafNode = SCNNode(geometry: blade); leafNode.scale = SCNVector3(0.07,0.20,0.014)
                leafNode.position = SCNVector3(x+dx,floor+1.12+Float(leaf%3)*0.09,5.15+dz)
                leafNode.eulerAngles = SCNVector3(0.30,angle,0.35); decor.addChildNode(leafNode)
            }
        }
        var sharedMaterials: [UIColor: SCNMaterial] = [:]
        for node in decor.childNodes {
            guard let surface = node.geometry?.firstMaterial, let color = surface.diffuse.contents as? UIColor else { continue }
            surface.lightingModel = .lambert
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
        roomSculpture = sculpture
        applyRoomSettings()
    }

    func start(in scene: SCNScene, head: SCNNode) {
        stop()
        isRunning = true; aligned = false; mode = .room
        sprayGate = GraffitiSprayGate(); colorIndex = 0; sizeIndex = 1
        rainbow = false; erasing = false; mood = .neon
        preferences = GraffitiPreferences.load(); settingsPage = false; radioPage = false
        audio.prepare(); audio.play(.palette)
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
            let canvas = GraffitiCanvas(size: size, base: UIColor(white: 0.80 - CGFloat(index) * 0.025, alpha: 1), textureWidth: 2048)
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
        audio.stop(); radio.stop()
        for anchor in paintAnchors { onRemoveAnchor?(anchor) }
        paintAnchors.removeAll()
        canvasAnchors.removeAll(); homeCanvases.removeAll(); roomCanvases.removeAll(); undo.removeAll()
        roomAccents.removeAll()
        props.clear(); roomSculpture = nil; radioNode = nil
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

    private func endStroke() { activeCanvas = nil; sampler.reset(); mist.isHidden = true; paintingHand = nil; audio.setSpraying(false); audio.setErasing(false) }

    private func stopSpraying() {
        sprayGate.cancel(); endStroke(); can.isHidden = true; aim.isHidden = true
    }

    func cancelInput() {
        props.cancel()
        stopSpraying(); uiGate.cancel(); ring.isHidden = true
        uiHand = nil; uiBlocked = false
    }

    func tick(at time: Double, trackingReady: Bool) {
        guard isRunning else { return }
        props.tick(at: time, ready: trackingReady && mode == .room && preferences.grabbing)
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
        var available = [("palette", paletteButton)] + (paletteOpen ? buttons.filter { !$0.1.node.isHidden } : [])
        if mode == .room, radioNode != nil, !props.isHeld(radioNode), !paletteOpen { available.append(("radio-world", radioButton)) }
        let target = ray.flatMap { ray in available.first { $0.1.hitTest(ray: ray) } }
        for (_, button) in available { button.setHighlight(button === target?.1) }
        let action = uiGate.update(target: target?.0, down: false, allowBegin: false, dwell: true, at: time)
        ring.show(on: target?.1.node, progress: uiGate.dwellProgress)
        if let action, perform(action) { audio.play(GraffitiSound.feedback(for: action)) }
        uiBlocked = target != nil || paletteOpen
        if uiBlocked { endStroke(); can.isHidden = true; aim.isHidden = true }
        return uiBlocked
    }

    func updateProp(hand: TrackedHand, generation: UInt64?, fist: Bool, open: Bool, ray: WorldRay?,
                    distance: Float, orientation: simd_quatf, blocked: Bool, trackingReady: Bool, at time: Double) {
        guard isRunning, aligned else { return }
        guard mode == .room, preferences.grabbing else { props.cancel(); return }
        props.update(hand: hand, generation: generation, fist: fist, open: open, ray: ray, distance: distance,
            orientation: orientation, blocked: blocked || uiBlocked || paletteOpen || !preferences.grabbing || mode != .room,
            ready: trackingReady, at: time)
    }

    func updateHand(hand: TrackedHand?, open: Bool, ray: WorldRay?, distance: Float, toolOffset: SIMD3<Float>,
                    blocked: Bool, trackingReady: Bool, at time: Double) {
        guard isRunning, aligned else { return }
        if mode == .room && preferences.grabbing && props.blocksPainting(hand) {
            stopSpraying(); return
        }
        if !preferences.paintEnabled {
            stopSpraying()
            if !paletteOpen { setHint("Краска выключена · «Цвет» → «Настройки»") }
            return
        }
        let spraying = sprayGate.update(hand: hand, open: open, reliable: trackingReady && ray != nil,
                                        blocked: blocked || uiBlocked || paletteOpen, at: time)
        guard let ray, trackingReady, hand != nil else {
            endStroke(); can.isHidden = true; aim.isHidden = true
            if trackingReady, !paletteOpen { setHint("Открой ладонь — рисовать · «Цвет» — палитра") }
            return
        }
        lastHandAt = time
        can.isHidden = erasing || !sprayGate.canVisible
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
            setHint(erasing ? "Направь стиралку на стену с рисунком" : (mode == .home ? (homeCanvases.count >= 12 ? "Лимит холстов сеанса · рисуй на уже начатой стене" : "Осмотри стену камерой, чтобы найти поверхность") : "Направь ладонь на стену"))
            return
        }
        aim.isHidden = false
        aim.simdWorldTransform = hit.canvas.node.simdWorldTransform
        let marker = hit.canvas.node.convertPosition(SCNVector3(Float(hit.point.x), Float(hit.point.y), 0.008), to: root)
        aim.simdPosition = SIMD3(marker.x, marker.y, marker.z)
        can.look(at: marker, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        // The small ring geometry lies in XZ; rotate its own mesh into the wall's XY.
        aim.simdWorldOrientation = hit.canvas.node.simdWorldOrientation * simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        let aimScale: Float = erasing ? Float(brushRadius/0.018) : 1
        aim.scale = SCNVector3(aimScale,aimScale,aimScale)
        if activeCanvas != hit.canvas.id {
            endStroke()
            guard let image = hit.canvas.snapshot() else { setHint("Не удалось создать холст"); return }
            activeCanvas = hit.canvas.id
            undo.append((hit.canvas.id, image)); if undo.count > 6 { undo.removeFirst() }
        }
        let points = sampler.points(to: hit.point, radius: brushRadius, at: time)
        paintingHand = hand
        let color = paintColor(at: time)
        canMaterial.diffuse.contents = color
        sculptureMaterial.diffuse.contents = color
        mist.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.16)
        hit.canvas.spray(points: points, radius: brushRadius, color: color, clip: hit.clip,
                         flow: preferences.flow, hardEdge: preferences.hardEdge, erasing: erasing)
        mist.isHidden = erasing
        audio.setSpraying(!erasing)
        audio.setErasing(erasing)
        setHint("\(erasing ? "Стиралка" : (rainbow ? "Радуга" : colors[colorIndex].0)) · убери или закрой ладонь — стоп")
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
            guard !erasing else { return nil }
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
        updateRadioControls()
        canMaterial.diffuse.contents = colors[colorIndex].1
        sculptureMaterial.diffuse.contents = colors[colorIndex].1
        mist.geometry?.firstMaterial?.diffuse.contents = colors[colorIndex].1.withAlphaComponent(0.16)
        for (id, button) in buttons {
            let tab = id.hasPrefix("tab-")
            let shown = id.hasPrefix("radio-") ? radioPage : (id.hasPrefix("setting-") ? settingsPage : !settingsPage && !radioPage)
            button.node.isHidden = !tab && !shown
            if id == "tab-paint" { button.setTitle(settingsPage || radioPage ? "Краска" : "✓ Краска") }
            if id == "tab-settings" { button.setTitle(settingsPage ? "✓ Настройки" : "Настройки") }
            if id.hasPrefix("color-"), let n = Int(id.dropFirst(6)) { button.setTitle((n == colorIndex ? "✓ " : "") + colors[n].0) }
            if id.hasPrefix("size-"), let n = Int(id.dropFirst(5)) { button.setTitle((n == sizeIndex ? "✓ " : "") + ["Тонко", "Средне", "Широко"][n]) }
            if id == "room" { button.setTitle(mode == .room ? "✓ Комната" : "Комната") }
            if id == "home" { button.setTitle(mode == .home ? "✓ Мои стены" : "Мои стены") }
            if id == "eraser" { button.setTitle(erasing ? "✓ Стиралка" : "Стиралка") }
            if id == "rainbow" { button.setTitle(rainbow ? "Радуга: вкл" : "Радуга: выкл") }
            if id == "mood" { button.setTitle("Свет: \(mood.title)") }
            if id == "setting-paint" { button.setTitle(preferences.paintEnabled ? "Краска: вкл" : "Краска: выкл") }
            if id == "setting-grab" { button.setTitle(preferences.grabbing ? "Захват: вкл" : "Захват: выкл") }
            if id == "setting-flow" { button.setTitle("Слой: \(["лёгкий", "обычный", "плотный"][preferences.density])") }
            if id == "setting-edge" { button.setTitle(preferences.hardEdge ? "Край: чёткий" : "Край: мягкий") }
            if id == "setting-light" { button.setTitle("Яркость: \(["низкая", "средняя", "высокая"][preferences.brightness])") }
            if id == "setting-grid" { button.setTitle(preferences.grid ? "Сетка: вкл" : "Сетка: выкл") }
            if id == "setting-animation" { button.setTitle(preferences.animation ? "Куб: вращается" : "Куб: стоит") }
            if id == "setting-sound" { button.setTitle(audio.enabled ? "Звук: вкл" : "Звук: выкл") }
            if id == "setting-volume" { button.setTitle("Громкость: \(audio.volumeTitle)") }
        }
    }

    private func updateRadioControls() {
        radioStatus.isHidden = !radioPage
        radioStatus.setText(radio.title); radioStatus.fitWidth(0.95)
        radioButton.setTitle(radio.isPlaying ? "Ⅱ" : "▶")
        for (id, button) in buttons {
            if id == "tab-radio" { button.setTitle(radioPage ? "✓ Радио" : "Радио") }
            if id == "radio-toggle" { button.setTitle(radio.isPlaying ? "Пауза" : "Включить") }
            if id == "radio-volume" { button.setTitle("Громкость: \(radio.volumeTitle)") }
        }
    }

    private func applyRoomSettings() {
        floorGrid.isHidden = !preferences.grid
        roomSculpture?.isPaused = !preferences.animation
        var pending = [room]
        while let node = pending.popLast() {
            pending.append(contentsOf: node.childNodes)
            for surface in node.geometry?.materials ?? [] {
                surface.multiply.contents = UIColor(white: preferences.light, alpha: 1)
            }
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
        if action.hasPrefix("tab-") { settingsPage = action == "tab-settings"; radioPage = action == "tab-radio" }
        if action == "radio-toggle" || action == "radio-world" { radio.toggle() }
        if action == "radio-next" { radio.next() }
        if action == "radio-volume" { radio.nextVolume() }
        if action == "radio-import" { onImportMusic?() }
        if action == "radio-own" { radio.ownMusic() }
        if action == "radio-default" { radio.builtIn(); radio.play() }
        if action == "radio-close" { setPalette(false) }
        if action == "setting-paint" { preferences.paintEnabled.toggle() }
        if action == "setting-grab" { preferences.grabbing.toggle(); props.cancel() }
        if action == "setting-flow" { preferences.density = (preferences.density+1)%3 }
        if action == "setting-edge" { preferences.hardEdge.toggle() }
        if action == "setting-light" { preferences.brightness = (preferences.brightness+1)%3 }
        if action == "setting-grid" { preferences.grid.toggle() }
        if action == "setting-animation" { preferences.animation.toggle() }
        if action == "setting-props" { props.reset() }
        if action == "setting-reset" { preferences = GraffitiPreferences(); audio.resetSettings() }
        if action == "setting-sound" { audio.toggle() }
        if action == "setting-volume" { audio.nextVolume() }
        if action == "setting-close" { setPalette(false) }
        if action.hasPrefix("setting-") { preferences.save(); applyRoomSettings() }
        if action.hasPrefix("color-"), let n = Int(action.dropFirst(6)), colors.indices.contains(n) { colorIndex = n; rainbow = false; erasing = false }
        if action == "rainbow" { rainbow.toggle(); erasing = false }
        if action == "eraser" { erasing.toggle() }
        if action == "mood" { mood = mood.next; updateRoomMood() }
        if action.hasPrefix("size-"), let n = Int(action.dropFirst(5)), radii.indices.contains(n) { sizeIndex = n }
        if action == "room" || action == "home" {
            props.cancel()
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
