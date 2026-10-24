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
    private let width = 1024
    private let height: Int
    private var context: CGContext?
    private(set) var dirty = false

    init(size: SIMD2<Double>, base: UIColor) {
        self.size = size; self.base = base
        height = max(1, Int(1024 * size.y / size.x))
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
    private let status = CineText()
    private let paletteButton = CineButton(title: "Цвет", color: .darkGray, width: 0.24, height: 0.16)
    private var buttons: [(String, CineButton)] = []
    private var uiGate = ReleaseClickGate<String>()
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
    var handOwner: TrackedHand? { sprayGate.owner }
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
        status.position = SCNVector3(0, -0.68, -1.5)
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
        box(SCNVector3(1.12, 0.98, 0.035), at: SCNVector3(0, -0.02, -1.36),
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
        button("undo", "Отменить", -0.27, -0.38, width: 0.49)
        button("exit", "В меню", 0.27, -0.38, width: 0.49)
        panel.isHidden = true
    }

    func start(in scene: SCNScene, head: SCNNode) {
        stop()
        isRunning = true; aligned = false; mode = .room
        sprayGate = GraffitiSprayGate(); colorIndex = 0; sizeIndex = 1
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
        for index in 0..<4 {
            let canvas = GraffitiCanvas(size: SIMD2(4.8, 3), base: UIColor(white: 0.82 - CGFloat(index) * 0.025, alpha: 1))
            let angle = Float(index) * .pi / 2
            canvas.node.position = SCNVector3(-sin(angle) * 2.4, 0, -cos(angle) * 2.4)
            canvas.node.eulerAngles.y = angle
            room.addChildNode(canvas.node); roomCanvases.append(canvas)
        }
        box(SCNVector3(4.85, 0.05, 4.85), at: SCNVector3(0, -1.52, 0), color: UIColor(white: 0.12, alpha: 1), parent: room)
        box(SCNVector3(4.85, 0.05, 4.85), at: SCNVector3(0, 1.52, 0), color: UIColor(white: 0.08, alpha: 1), parent: room)
        for x: Float in [-2.36, 2.36] {
            box(SCNVector3(0.025, 0.025, 4.7), at: SCNVector3(x, 1.42, 0), color: .systemCyan, parent: room)
        }
        recenterControls(head: head)
        setHint("Кулак — рисовать · «Цвет» — палитра")
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

    private func endStroke() { activeCanvas = nil; sampler.reset(); mist.isHidden = true }

    func cancelInput() {
        sprayGate.cancel(); endStroke(); uiGate.cancel(); ring.isHidden = true
        can.isHidden = true; aim.isHidden = true
    }

    func tick(at time: Double, trackingReady: Bool) {
        guard isRunning else { return }
        if !trackingReady || time - lastHandAt > 0.2 { sprayGate.cancel(); endStroke(); can.isHidden = true; aim.isHidden = true }
        if !trackingReady { uiGate.cancel(); ring.isHidden = true; setHint("Ожидаю устойчивое отслеживание камеры…") }
        if time - lastUpload >= 1.0 / 15 {
            for canvas in roomCanvases + homeCanvases where canvas.dirty { canvas.upload() }
            lastUpload = time
        }
    }

    /// Open hands control UI, fists control paint. A head ray may control UI only.
    func updateUI(ray: WorldRay?, fist: Bool = false, at time: Double) -> Bool {
        guard isRunning, aligned else { return false }
        let available = [("palette", paletteButton)] + (paletteOpen ? buttons : [])
        let target = ray.flatMap { ray in available.first { $0.1.hitTest(ray: ray) } }
        for (_, button) in available { button.setHighlight(button === target?.1) }
        guard !fist else { uiGate.cancel(); ring.isHidden = true; return target != nil || paletteOpen }
        let action = uiGate.update(target: target?.0, down: false, allowBegin: false, dwell: true, at: time)
        ring.show(on: target?.1.node, progress: uiGate.dwellProgress)
        if let action { perform(action); onInteraction?() }
        return target != nil || paletteOpen
    }

    func updateHand(hand: TrackedHand?, fist: Bool, open: Bool, ray: WorldRay?, distance: Float,
                    blocked: Bool, trackingReady: Bool, at time: Double) {
        guard isRunning, aligned else { return }
        let spraying = sprayGate.update(hand: hand, fist: fist, open: open, reliable: trackingReady && ray != nil,
                                        blocked: blocked || paletteOpen, at: time)
        guard let ray, trackingReady, hand != nil else { endStroke(); can.isHidden = true; aim.isHidden = true; return }
        lastHandAt = time
        can.isHidden = !sprayGate.canVisible
        can.simdWorldPosition = ray.point(at: distance)
        can.look(at: SCNVector3(ray.point(at: distance + 1)), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        guard fist, !blocked, !paletteOpen else { endStroke(); aim.isHidden = true; return }
        guard spraying else {
            endStroke(); aim.isHidden = true
            setHint("Раскрой ладонь, затем снова сожми кулак"); return
        }
        guard let hit = paintHit(ray: ray) else {
            endStroke(); aim.isHidden = true
            setHint(mode == .home ? (homeCanvases.count >= 12 ? "Лимит холстов сеанса · рисуй на уже начатой стене" : "Осмотри стену камерой, чтобы найти поверхность") : "Направь кулак на стену")
            return
        }
        aim.isHidden = false
        aim.simdWorldTransform = hit.canvas.node.simdWorldTransform
        let marker = hit.canvas.node.convertPosition(SCNVector3(Float(hit.point.x), Float(hit.point.y), 0.008), to: root)
        aim.simdPosition = SIMD3(marker.x, marker.y, marker.z)
        // The small ring geometry lies in XZ; rotate its own mesh into the wall's XY.
        aim.simdWorldOrientation = hit.canvas.node.simdWorldOrientation * simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        if activeCanvas != hit.canvas.id {
            endStroke()
            guard let image = hit.canvas.snapshot() else { setHint("Не удалось создать холст"); return }
            activeCanvas = hit.canvas.id
            undo.append((hit.canvas.id, image)); if undo.count > 6 { undo.removeFirst() }
        }
        let points = sampler.points(to: hit.point, radius: radii[sizeIndex], at: time)
        hit.canvas.spray(points: points, radius: radii[sizeIndex], color: colors[colorIndex].1, clip: hit.clip)
        mist.isHidden = false
        setHint("\(colors[colorIndex].0) · раскрой руку, чтобы остановиться")
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
                guard t > 0.15, t < 8 else { continue }
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
        setHint(open ? "Рисунки этого сеанса удалятся при выходе в меню" : "Кулак — рисовать · «Цвет» — палитра")
        sprayGate.cancel(); endStroke(); can.isHidden = true
        // Keep the dwell latch until the pointer leaves the toggle button.
    }

    private func updateSelection() {
        canMaterial.diffuse.contents = colors[colorIndex].1
        mist.geometry?.firstMaterial?.diffuse.contents = colors[colorIndex].1.withAlphaComponent(0.16)
        for (id, button) in buttons {
            if id.hasPrefix("color-"), let n = Int(id.dropFirst(6)) { button.setTitle((n == colorIndex ? "✓ " : "") + colors[n].0) }
            if id.hasPrefix("size-"), let n = Int(id.dropFirst(5)) { button.setTitle((n == sizeIndex ? "✓ " : "") + ["Тонко", "Средне", "Широко"][n]) }
            if id == "room" { button.setTitle(mode == .room ? "✓ Комната" : "Комната") }
            if id == "home" { button.setTitle(mode == .home ? "✓ Мои стены" : "Мои стены") }
        }
    }

    private func perform(_ action: String) {
        if action == "palette" { setPalette(!paletteOpen); return }
        sprayGate.cancel(); endStroke()
        if action.hasPrefix("color-"), let n = Int(action.dropFirst(6)), colors.indices.contains(n) { colorIndex = n }
        if action.hasPrefix("size-"), let n = Int(action.dropFirst(5)), radii.indices.contains(n) { sizeIndex = n }
        if action == "room" || action == "home" {
            mode = action == "room" ? .room : .home
            room.isHidden = mode != .room; home.isHidden = mode != .home
            onModeChanged?(mode)
            setHint(mode == .home ? "Осмотри стену камерой · закрой палитру" : "Закрой палитру и сожми кулак")
        }
        let visibleCanvases = mode == .room ? roomCanvases : homeCanvases
        if action == "undo", let index = undo.lastIndex(where: { entry in visibleCanvases.contains { $0.id == entry.0 } }) {
            let entry = undo.remove(at: index)
            if let canvas = visibleCanvases.first(where: { $0.id == entry.0 }) { canvas.restore(entry.1); canvas.upload() }
        }
        if action == "exit" { onExit?() }
        updateSelection()
    }
}
