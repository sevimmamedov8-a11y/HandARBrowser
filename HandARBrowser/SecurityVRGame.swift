import SceneKit
import simd
import UIKit

// MARK: - Мелочи для материалов

private extension SCNMaterial {
    /// Ровный цвет без освещения — работает в пасстр-режиме с обоими глазами.
    func applyConstant(_ color: UIColor, emissive: CGFloat = 0.0) {
        lightingModel = .constant
        diffuse.contents = color
        if emissive > 0 {
            emission.contents = color.withAlphaComponent(emissive)
        }
    }
}

private extension SCNVector3 {
    var simd3: SIMD3<Float> {
        SIMD3<Float>(Float(x), Float(y), Float(z))
    }
}

// MARK: - Пересечение луча со сферой

private func sphereHit(ray: WorldRay, center: SIMD3<Float>, radius: Float) -> Float? {
    let oc = ray.origin - center
    let a = simd_dot(ray.direction, ray.direction)
    let b = 2 * simd_dot(oc, ray.direction)
    let c = simd_dot(oc, oc) - radius * radius
    let discriminant = b * b - 4 * a * c
    guard discriminant >= 0 else { return nil }
    let t = (-b - discriminant.squareRoot()) / (2 * a)
    return t > 0 ? t : nil
}

// MARK: - Рендер надписи в картинку (кириллица + эмодзи)

private func renderLabelImage(
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

// MARK: - Текстовая плашка (всегда к лицу)

private final class TextSprite: SCNNode {
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

    var maximumWidth: Float?

    func setText(_ value: String, color: UIColor = .white) {
        guard value != current else { return }
        current = value
        if let image = renderLabelImage(value, color: color, fontSize: 52) {
            plane.width = image.size.width
            plane.height = image.size.height
            if let maximumWidth {
                let size = min(Float(0.0013),maximumWidth / Float(plane.width))
                scale = SCNVector3(size,size,size)
            }
            planeNode.geometry?.firstMaterial?.diffuse.contents = image
            planeNode.isHidden = false
        } else {
            planeNode.isHidden = true
        }
    }

    /// Масштаб так, чтобы надпись была `width` метров шириной.
    func fitWidth(_ width: Float) {
        guard plane.width > 1 else { return }
        let scale = width / Float(plane.width)
        self.scale = SCNVector3(scale, scale, scale)
    }
}

// MARK: - 3D-кнопка

private final class SecurityButton {
    let node = SCNNode()
    let hitRadius: Float
    private let plate: SCNNode
    private let base: UIColor

    init(title: String, color: UIColor, hitRadius: Float = 0.26, fontSize: CGFloat = 5.2) {
        self.base = color
        self.hitRadius = hitRadius

        let box = SCNBox(width: 0.44, height: 0.17, length: 0.02, chamferRadius: 0.032)
        let material = SCNMaterial()
        material.applyConstant(color.withAlphaComponent(0.95))
        box.materials = [material]
        plate = SCNNode(geometry: box)
        node.addChildNode(plate)

        // Надпись рисуем в картинку и вписываем в табличку —
        // так кириллица и эмодзи гарантированно видны.
        _ = fontSize
        if let image = renderLabelImage(title, color: .white, fontSize: 64, weight: .bold) {
            let labelPlane = SCNPlane(width: image.size.width, height: image.size.height)
            let textMaterial = SCNMaterial()
            textMaterial.lightingModel = .constant
            textMaterial.isDoubleSided = true
            textMaterial.diffuse.contents = image
            labelPlane.materials = [textMaterial]
            let textNode = SCNNode(geometry: labelPlane)
            let fit = Float(min(0.40 / Double(image.size.width), 0.115 / Double(image.size.height)))
            textNode.scale = SCNVector3(fit, fit, fit)
            textNode.position = SCNVector3(0, 0, 0.014)
            plate.addChildNode(textNode)
        }
        node.constraints = [SCNBillboardConstraint()]
    }

    func hitTest(ray: WorldRay) -> Bool {
        guard !node.isHidden else { return false }
        return sphereHit(
            ray: ray,
            center: node.presentation.simdWorldPosition,
            radius: hitRadius * abs(node.scale.x)
        ) != nil
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

// MARK: - Моя рука (тащится за настоящей рукой)

/// Ладонь + 4 пальца + большой. Следует за лучом кончика указательного
/// пальца, поэтому хват выходит «рука к руке», а не взглядом.
private final class MyHand {
    let node = SCNNode()
    private var fingers: [SCNNode] = []
    private(set) var worldPosition = SIMD3<Float>(0, 0, 0)
    private(set) var worldSpeed: Float = 0
    private var hasPosition = false

    init() {
        let skin = SCNMaterial()
        skin.applyConstant(UIColor(red: 0.82, green: 0.62, blue: 0.45, alpha: 1))

        let palmGeometry = SCNBox(width: 0.16, height: 0.075, length: 0.052, chamferRadius: 0.024)
        palmGeometry.materials = [skin]
        node.addChildNode(SCNNode(geometry: palmGeometry))

        let fingerXs: [Float] = [-0.058, -0.019, 0.020, 0.058]
        for (index, x) in fingerXs.enumerated() {
            let length: Float = index == 1 ? 0.09 : 0.078
            let geometry = SCNBox(
                width: 0.028, height: CGFloat(length), length: 0.028, chamferRadius: 0.012
            )
            geometry.materials = [skin]
            let pivot = SCNNode()
            pivot.position = SCNVector3(x, 0.042, 0)
            let finger = SCNNode(geometry: geometry)
            finger.position = SCNVector3(0, length * 0.5, 0)
            pivot.addChildNode(finger)
            node.addChildNode(pivot)
            fingers.append(pivot)
        }

        let thumbGeometry = SCNBox(width: 0.030, height: 0.082, length: 0.032, chamferRadius: 0.012)
        thumbGeometry.materials = [skin]
        let thumb = SCNNode(geometry: thumbGeometry)
        thumb.position = SCNVector3(-0.088, 0.008, 0.012)
        thumb.eulerAngles = SCNVector3(0, 0, -0.8)
        thumb.scale = SCNVector3(1, 1, 1)
        node.addChildNode(thumb)
        fingers.append(thumb)
    }

    /// Ставим кисть в точку луча и направляем пальцы вперёд по лучу.
    func update(targetWorld: SIMD3<Float>, direction: SIMD3<Float>, dt: Float, gripping: Bool) {
        let previous = worldPosition
        worldPosition = targetWorld
        if hasPosition, dt > 0.001 {
            let instant = simd_length(targetWorld - previous) / dt
            worldSpeed = instant * 0.35 + worldSpeed * 0.65
        } else { worldSpeed = 0 }
        hasPosition = true
        node.simdPosition = targetWorld
        node.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: simd_normalize(direction)
        )
        // Кулак — пальцы поджимаются.
        let curl = gripping ? 0.55 : 1.0
        for (index, finger) in fingers.enumerated() {
            if index == fingers.count - 1 { continue }
            finger.eulerAngles.x = gripping ? -1.15 : 0
            finger.scale = SCNVector3(1, curl, 1)
        }
    }

    func resetMotion() {
        hasPosition = false
        worldSpeed = 0
    }

    func reset() {
        resetMotion()
        node.removeFromParentNode()
    }
}

// MARK: - Инструмент охраны

private enum SecurityTool: Int, CaseIterable {
    case scanner
    case breathalyzer
    case waterPistol
    case taser
    case hand

    var title: String {
        switch self {
        case .scanner: return "📡 СКАНЕР"
        case .breathalyzer: return "🫁 АЛКО"
        case .waterPistol: return "💦 ВОДЯНКА"
        case .taser: return "⚡ ШОКЕР"
        case .hand: return "✋ РУКА"
        }
    }

    var color: UIColor {
        switch self {
        case .scanner: return UIColor(red: 0.12, green: 0.55, blue: 0.95, alpha: 1)
        case .breathalyzer: return UIColor(red: 0.12, green: 0.75, blue: 0.45, alpha: 1)
        case .waterPistol: return UIColor(red: 0.15, green: 0.70, blue: 0.90, alpha: 1)
        case .taser: return UIColor(red: 0.95, green: 0.80, blue: 0.10, alpha: 1)
        case .hand: return UIColor(red: 0.98, green: 0.55, blue: 0.22, alpha: 1)
        }
    }
}

// MARK: - Гость (процедурный персонаж)

private enum GuestPhase {
    case arriving
    case atGate
    case leaving
    case attacking
    case stunned
    case held       // схвачен рукой и висит в воздухе
    case dropping  // брошен, падает на пол
}

private enum ScanKind {
    case body
    case face
}

private final class SecurityGuest {
    let root = SCNNode()
    private(set) var phase: GuestPhase = .arriving
    private(set) var arrived = false
    private(set) var leftScene = false
    let id = UUID()
    let arrivalWave: Int
    var resolved = false
    var goods: [UUID:(kind:SecurityGoods,node:SCNNode)] = [:]
    var hasContraband: Bool { goods.values.contains { $0.kind.forbidden(wave:arrivalWave) } }
    private var ragdoll: SecurityRagdoll?
    private var ragdollView: SecurityRagdollView?
    private(set) var knockdownCounts = false
    let isDrunk: Bool
    let isAggressive: Bool
    private(set) var scanned = false
    private(set) var breathTested = false
    private(set) var subdued = false

    private let speed: Float
    private var walkClock: Float = 1.7
    private let porchTarget: Float = 0.45
    private let playerTarget: Float = 0.72

    private var torso = SCNNode()
    private var legPivots: [SCNNode] = []
    private var armPivots: [SCNNode] = []

    private var contrabandNode = SCNNode()
    private var bottleNode = SCNNode()
    private var scanRing = SCNNode()
    private var scanBar = SCNNode()
    private let verdict = TextSprite()
    private let nameTag = TextSprite()
    private(set) var displayName = "Гость"
    private var resumePhase: GuestPhase = .atGate
    private var dropVelocity: Float = 0
    private var armTips: [SCNNode] = []

    private var scanProgress: Float = 0
    private var activeScan: ScanKind?
    private var walkedInward = true
    private var stunTimer: Float = 0

    init(hasContraband: Bool, isDrunk: Bool, isAggressive: Bool, speed: Float, wave: Int = 1) {
        self.arrivalWave = wave
        self.isDrunk = isDrunk
        self.isAggressive = isAggressive
        self.speed = speed
        buildBody()
        buildScanUI()
        let cargo: SecurityGoods = hasContraband ? .sealedCase : [.camera,.skateboard,.headphones,.speaker].randomElement()!
        addGoods(cargo,at:SIMD3(0.28,1.06,-0.18))
        if Bool.random() { addGoods(.chain,at:SIMD3(0,1.30,0.135)) }
        if isDrunk { addGoods(.bottle,at:SIMD3(-0.30,0.82,0.08)) }
    }

    private func addGoods(_ kind: SecurityGoods, at point: SIMD3<Float>) {
        let node = SecurityModels.make(kind); node.simdPosition = point
        if kind != .chain { node.eulerAngles.z = -0.15 }
        root.addChildNode(node); goods[UUID()] = (kind,node)
    }

    func removeGoods(_ id: UUID) -> SCNNode? {
        guard let item = goods.removeValue(forKey:id) else { return nil }
        item.node.removeFromParentNode(); refreshNameTag()
        if scanned { verdict.setText(hasContraband ? "Остались запрещённые вещи" : "Вещи в порядке",color:hasContraband ? .systemRed : .systemGreen) }
        return item.node
    }

    func knockDown(impulse: SIMD3<Float>, accountable: Bool = true) {
        guard ragdoll == nil, !leftScene else { return }
        cancelScan(); phase = .dropping; knockdownCounts = accountable
        let visibleGoods = goods.values.map { $0.node }
        for node in root.childNodes where !visibleGoods.contains(where: { $0 === node }) { node.isHidden = true }
        let p = root.simdPosition
        ragdoll = SecurityRagdoll(impulse:impulse,floor:-p.y,
            low:SIMD3(-3.3-p.x,-10,-3.8-p.z),high:SIMD3(3.3-p.x,3.35-p.y,3.1-p.z),
            obstacles:[SecurityRagdoll.Obstacle(low:SIMD3(-2.05,0.74,0.55)-p,high:SIMD3(-0.45,0.84,1.25)-p)])
        if let view = ragdollView { root.addChildNode(view.root) }
    }

    private func bodyMaterials() -> (skin: SCNMaterial, hair: SCNMaterial, shirt: SCNMaterial) {
        let skin = SCNMaterial()
        if isDrunk {
            skin.applyConstant(UIColor(
                red: .random(in: 0.75...1.0),
                green: .random(in: 0.40...0.60),
                blue: 0.55,
                alpha: 1
            ))
        } else {
            skin.applyConstant(UIColor(
                red: .random(in: 0.55...0.95),
                green: .random(in: 0.45...0.85),
                blue: 0.72,
                alpha: 1
            ))
        }
        let hair = SCNMaterial()
        hair.applyConstant(UIColor(
            red: .random(in: 0...0.4),
            green: .random(in: 0...0.3),
            blue: 0.05,
            alpha: 1
        ))
        let shirtColor = UIColor(
            red: isAggressive ? .random(in: 0.6...0.9) : .random(in: 0...0.65),
            green: .random(in: 0...0.5),
            blue: 0.0,
            alpha: 1
        )
        let shirt = SCNMaterial()
        shirt.applyConstant(shirtColor)
        for material in [skin,hair,shirt] {
            material.lightingModel = .physicallyBased; material.roughness.contents = 0.75
        }
        return (skin, hair, shirt)
    }

    private func buildBody() {
        let (skin, hair, shirt) = bodyMaterials()

        let trousers = SecurityModels.material(UIColor(red:0.10,green:0.12,blue:0.17,alpha:1),rough:0.85)
        // Ноги — повороты от бёдер.
        for side in [-1, 1] {
            let pivot = SCNNode()
            pivot.position = SCNVector3(0.11 * Float(side), 0.82, 0)
            let leg = SCNBox(width: 0.10, height: 0.78, length: 0.11, chamferRadius: 0.04)
            leg.materials = [trousers]
            let legNode = SCNNode(geometry: leg)
            legNode.position = SCNVector3(0, -0.39, 0)
            pivot.addChildNode(legNode)
            root.addChildNode(pivot)
            legPivots.append(pivot)
        }

        // Торс
        let body = SCNBox(width: 0.36, height: 0.50, length: 0.20, chamferRadius: 0.06)
        body.materials = [shirt]
        torso = SCNNode(geometry: body)
        torso.position = SCNVector3(0, 1.07, 0)
        root.addChildNode(torso)

        // Руки с кистями
        for side in [-1, 1] {
            let pivot = SCNNode()
            pivot.position = SCNVector3(0.24 * Float(side), 1.30, 0)
            let arm = SCNBox(width: 0.085, height: 0.62, length: 0.085, chamferRadius: 0.03)
            arm.materials = [shirt]
            let armNode = SCNNode(geometry: arm)
            armNode.position = SCNVector3(0, -0.31, 0)
            let hand = SCNSphere(radius: 0.062)
            hand.materials = [skin]
            let handNode = SCNNode(geometry: hand)
            handNode.position = SCNVector3(0, -0.655, 0)
            pivot.addChildNode(armNode)
            pivot.addChildNode(handNode)
            root.addChildNode(pivot)
            armPivots.append(pivot)
            armTips.append(handNode)
        }

        // Голова + волосы
        let head = SCNSphere(radius: 0.135)
        head.materials = [skin]
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, 1.50, 0)
        root.addChildNode(headNode)

        let hairCap = SCNSphere(radius: 0.14)
        hairCap.materials = [hair]
        let hairNode = SCNNode(geometry: hairCap)
        hairNode.position = SCNVector3(0, 1.535, -0.012)
        hairNode.scale = SCNVector3(1, 0.55, 1)
        root.addChildNode(hairNode)

        buildFace(skin: skin, hair: hair)

        for side in [Float(-1),1] {
            let shoe = SecurityModels.box(root,SIMD3(0.14,0.10,0.26),SIMD3(side*0.11,0.065,0.07),SecurityModels.material(UIColor(white:0.08,alpha:1)),bevel:0.025)
            SecurityModels.box(shoe,SIMD3(0.145,0.025,0.265),SIMD3(0,-0.043,0),SecurityModels.material(UIColor(white:0.85,alpha:1)),bevel:0.009)
        }
        SecurityModels.box(root,SIMD3(0.012,0.40,0.015),SIMD3(0,1.08,0.108),SecurityModels.material(UIColor(white:0.65,alpha:1),metal:0.6),bevel:0.003)
        let headModel = SCNNode()
        for node in root.childNodes where node.position.y>=1.36 && node.position.y<1.73 {
            let clone = node.clone(); clone.position.y -= 1.50; headModel.addChildNode(clone)
        }
        ragdollView = SecurityRagdollView(skin:skin,cloth:shirt,headModel:headModel)

        // Плашка и имя над головой
        verdict.setText("...")
        verdict.position = SCNVector3(0, 1.86, 0)
        verdict.maximumWidth = 0.55
        verdict.scale = SCNVector3(0.0012, 0.0012, 0.0012)
        root.addChildNode(verdict)

        nameTag.setText("🙂 \(displayName)")
        nameTag.position = SCNVector3(0, 2.15, 0)
        nameTag.maximumWidth = 0.45
        nameTag.scale = SCNVector3(0.0012, 0.0012, 0.0012)
        root.addChildNode(nameTag)
    }

    func setName(_ name: String) {
        displayName = name
        refreshNameTag()
    }

    private func refreshNameTag() {
        var text = "🙂 \(displayName)"
        if scanned && hasContraband { text += " 📦" }
        if breathTested && isDrunk { text += " 🍺" }
        if phase == .attacking { text += " 😡" }
        nameTag.setText(text)
    }

    private func buildScanUI() {
        let ring = SCNCylinder(radius: 0.36, height: 0.006)
        let ringMaterial = SCNMaterial()
        ringMaterial.applyConstant(UIColor(red: 0.25, green: 0.75, blue: 1, alpha: 0.6), emissive: 0.5)
        ring.materials = [ringMaterial]
        scanRing = SCNNode(geometry: ring)
        scanRing.constraints = [SCNBillboardConstraint()]
        scanRing.position = SCNVector3(0, 0.95, 0.25)
        scanRing.isHidden = true
        root.addChildNode(scanRing)

        let back = SCNBox(width: 0.46, height: 0.03, length: 0.01, chamferRadius: 0.01)
        let backMaterial = SCNMaterial()
        backMaterial.applyConstant(UIColor(white: 0.15, alpha: 0.9))
        back.materials = [backMaterial]
        let backNode = SCNNode(geometry: back)
        backNode.position = SCNVector3(0, 1.33, 0.22)
        backNode.constraints = [SCNBillboardConstraint()]
        root.addChildNode(backNode)

        let fill = SCNBox(width: 0.42, height: 0.022, length: 0.012, chamferRadius: 0.008)
        let fillMaterial = SCNMaterial()
        fillMaterial.applyConstant(UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 1), emissive: 0.9)
        fill.materials = [fillMaterial]
        scanBar = SCNNode(geometry: fill)
        scanBar.position = SCNVector3(0, 1.33, 0.23)
        scanBar.scale = SCNVector3(0.001, 1, 1)
        scanBar.constraints = [SCNBillboardConstraint()]
        scanBar.isHidden = true
        root.addChildNode(scanBar)
    }

    // MARK: Лицо

    private func buildFace(skin: SCNMaterial, hair: SCNMaterial) {
        let white = SCNMaterial()
        white.applyConstant(UIColor(white: 0.97, alpha: 1))
        let black = SCNMaterial()
        black.applyConstant(UIColor(white: 0.03, alpha: 1))
        let brow = SCNMaterial()
        let hairColor = (hair.diffuse.contents as? UIColor) ?? UIColor(white: 0.2, alpha: 1)
        brow.applyConstant(hairColor)

        // Уши
        for side in [-1, 1] {
            let ear = SCNSphere(radius: 0.028)
            ear.materials = [skin]
            let earNode = SCNNode(geometry: ear)
            earNode.position = SCNVector3(0.135 * Float(side), 1.50, 0)
            earNode.scale = SCNVector3(0.5, 1, 0.8)
            root.addChildNode(earNode)
        }

        // Глаза: белок + зрачок + брови
        for side in [-1, 1] {
            let eye = SCNSphere(radius: 0.030)
            eye.materials = [white]
            let eyeNode = SCNNode(geometry: eye)
            eyeNode.position = SCNVector3(0.052 * Float(side), 1.515, 0.085)
            eyeNode.scale = SCNVector3(1, 1.15, 0.7)
            root.addChildNode(eyeNode)

            let pupil = SCNSphere(radius: 0.013)
            pupil.materials = [black]
            let pupilNode = SCNNode(geometry: pupil)
            pupilNode.position = SCNVector3(0.052 * Float(side), 1.515, 0.106)
            root.addChildNode(pupilNode)

            let browBar = SCNBox(width: 0.052, height: 0.010, length: 0.012, chamferRadius: 0.004)
            browBar.materials = [brow]
            let browNode = SCNNode(geometry: browBar)
            // Пьяный и злой сводят брови.
            browNode.position = SCNVector3(
                0.052 * Float(side),
                1.556 + ((isDrunk || isAggressive) ? 0.005 : 0),
                0.095
            )
            browNode.eulerAngles.z = ((isDrunk || isAggressive) ? -0.24 : -0.05) * Float(side)
            root.addChildNode(browNode)
        }

        // Нос
        let nose = SCNBox(width: 0.026, height: 0.045, length: 0.030, chamferRadius: 0.010)
        nose.materials = [skin]
        let noseNode = SCNNode(geometry: nose)
        noseNode.position = SCNVector3(0, 1.478, 0.113)
        noseNode.eulerAngles.x = 0.15
        root.addChildNode(noseNode)

        // Рот — у пьяного чуть открыт, у злого краснее.
        let mouth = SCNBox(
            width: isDrunk ? 0.062 : 0.050,
            height: isDrunk ? 0.020 : 0.012,
            length: 0.012,
            chamferRadius: 0.004
        )
        let mouthMaterial = SCNMaterial()
        mouthMaterial.applyConstant(
            isAggressive ? UIColor(red: 0.45, green: 0.06, blue: 0.10, alpha: 1)
                : UIColor(red: 0.55, green: 0.14, blue: 0.16, alpha: 1)
        )
        mouth.materials = [mouthMaterial]
        let mouthNode = SCNNode(geometry: mouth)
        mouthNode.position = SCNVector3(0, 1.428, 0.108)
        mouthNode.eulerAngles.x = -0.12
        root.addChildNode(mouthNode)
    }

    /// Кисти рук — именно за них хватает игрок.
    func handTipNodes() -> [SCNNode] { armTips }

    // MARK: Геометрия для попаданий

    func chestLocalPoint() -> SCNVector3 {
        SCNVector3(torso.position.x, torso.position.y + 0.08, torso.position.z)
    }

    func headLocalPoint() -> SCNVector3 {
        SCNVector3(0, 1.50, 0)
    }

    // MARK: Диалог

    func talkPhrase() -> String {
        if phase == .attacking { return "😡 ВОТ ПОЛУЧИ!" }
        if isAggressive { return ["Не приставай!", "Чё смотришь?", "А ну отойди!"].randomElement()! }
        if isDrunk { return ["Мне ещё пять...", "Ты же охрана? Пусти-и!", "Я почти трезвый..."].randomElement()! }
        if hasContraband { return ["У меня ничего нет.", "Быстрее пропускай.", "Я опаздываю..."].randomElement()! }
        return ["Добрый вечер!", "Красная дорожка где?", "Пусти, я чистый."].randomElement()!
    }

    func reactToWater() -> String {
        isAggressive ? "💦 БЛЯХА! МОКРЫЙ!" : "💦 ФУ, ЧТО ТВОРИШЬ?!"
    }

    func reactToTaser() -> String {
        isAggressive ? "⚡ ААА! ХВАТИТ!" : "⚡ ЗА ЧТО?!"
    }

    // MARK: Обновление

    func update(dt: Float) {
        walkClock += dt

        switch phase {
        case .arriving:
            root.position.z = min(root.position.z + speed * dt, porchTarget)
            swingLimbs(factor: 1.0)
            if root.position.z >= porchTarget {
                phase = .atGate
                arrived = true
            }
        case .atGate:
            swingLimbs(factor: 0.08)
        case .attacking:
            root.position.z = min(root.position.z + speed * 2.1 * dt, playerTarget)
            swingLimbs(factor: 1.3)
        case .stunned:
            stunTimer -= dt
            if stunTimer <= 0 {
                phase = .leaving
                walkedInward = false
            }
        case .held:
            // Висит в кулаке: ногами дрыгает, а схваченная рука почти не машет,
            // иначе хват «рука к руке» начинал бы трястись.
            swingLimbs(factor: 1.5, armScale: 0.22)
        case .dropping:
            if var state = ragdoll {
                state.update(dt:dt); ragdoll = state; ragdollView?.update(state)
                for item in goods.values {
                    let offset = item.kind == .chain ? SIMD3<Float>(0,0.08,0.13) : SIMD3<Float>(0.22,-0.05,-0.15)
                    item.node.simdPosition = state.points[1]+offset
                }
                if state.elapsed>5 { leftScene = true }
            }
        case .leaving:
            let direction: Float = walkedInward ? -1 : 1
            root.position.z += 1.15 * dt * direction
            swingLimbs(factor: 1.0)
            if root.position.z <= -3.2 || root.position.z >= 2.4 {
                leftScene = true
            }
        }
    }

    private func swingLimbs(factor: Float, armScale: Float = 1.0) {
        let gait: Float = isDrunk ? 1.9 : 2.6
        let swing = sin(walkClock * gait) * 0.9 * factor
        for (index, pivot) in legPivots.enumerated() {
            pivot.eulerAngles.x = index == 0 ? swing : -swing
        }
        for (index, pivot) in armPivots.enumerated() {
            pivot.eulerAngles.x = index == 0 ? -swing * 0.8 * armScale : swing * 0.8 * armScale
        }
        torso.position.y = Float(1.07) + abs(sin(walkClock * gait)) * 0.02 * factor
        // Пьяный шатается из стороны в сторону.
        let sway = isDrunk ? sin(walkClock * 1.5) * 0.14 * max(factor, 0.5) : 0
        torso.eulerAngles.z = sway
        root.eulerAngles.z = isDrunk && phase != .stunned ? sway * 0.4 : 0
    }

    // MARK: Сканирование

    func beginScan(kind: ScanKind) {
        guard phase == .atGate else { return }
        if kind == .body, scanned { return }
        if kind == .face, breathTested { return }
        guard activeScan != kind else { return }
        activeScan = kind
        scanProgress = 0
        scanBar.isHidden = false
        scanRing.isHidden = false
        if kind == .body {
            scanRing.position = SCNVector3(0, 0.95, 0.25)
            scanBar.position = SCNVector3(0, 1.33, 0.23)
            scanBar.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 1)
            verdict.setText("🔍 Сканирую грудь...")
        } else {
            scanRing.position = SCNVector3(0, 1.50, 0.22)
            scanBar.position = SCNVector3(0, 1.66, 0.20)
            scanBar.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.35, green: 1.0, blue: 0.55, alpha: 1)
            verdict.setText("🫁 Дуй в алкотестер...")
        }
    }

    func cancelScan() {
        activeScan = nil
        scanProgress = 0
        scanRing.isHidden = true
        scanBar.isHidden = true
    }

    @discardableResult
    func addScanProgress(_ delta: Float) -> Bool {
        guard let kind = activeScan else { return false }
        scanProgress = min(scanProgress + delta, 1)
        scanBar.scale = SCNVector3(max(scanProgress, 0.001), 1, 1)
        if scanProgress >= 1 {
            activeScan = nil
            scanRing.isHidden = true
            scanBar.isHidden = true
            switch kind {
            case .body:
                scanned = true
                verdict.setText(hasContraband ? "📦 ЗАПРЕТ!" : "✅ ЧИСТО",
                                color: hasContraband ? .systemRed : .systemGreen)
            case .face:
                breathTested = true
                verdict.setText(isDrunk ? "🍺 ПЬЯНИЦА!" : "😌 ТРЕЗВЫЙ",
                                color: isDrunk ? .systemOrange : .systemGreen)
            }
            refreshNameTag()
            return true
        }
        return false
    }

    func showVerdict(_ text: String, color: UIColor) {
        verdict.setText(text, color: color)
    }

    // MARK: Действия инструментов

    func applyWater() {
        showVerdict(reactToWater(), color: .systemBlue)
        cancelScan()
        if isAggressive {
            phase = .leaving
            walkedInward = false
            subdued = true
        }
    }

    func applyTaser() {
        showVerdict(reactToTaser(), color: .systemYellow)
        cancelScan()
        knockDown(impulse:SIMD3(0,0.7,-1.2))
        stunTimer = 2.0
        subdued = isAggressive
    }

    func beginAttack() {
        guard phase == .atGate else { return }
        phase = .attacking
        refreshNameTag()
        showVerdict("😡 ВОТ ПОЛУЧИ!", color: .systemRed)
    }

    func wasHitByPlayer() {
        phase = .leaving
        walkedInward = false
    }

    func leave(accepted: Bool) {
        phase = .leaving
        walkedInward = accepted
        verdict.setText(accepted ? "✅ ВНУТРИ" : "🚫 ОТКАЗ", color: accepted ? .systemGreen : .systemOrange)
    }

    // MARK: Захват рукой

    func applyTaserOnPunch() {
        guard phase != .held, phase != .leaving, phase != .dropping else { return }
        cancelScan()
        knockDown(impulse:SIMD3(0,1,-2.2))
        stunTimer = 0.8
        refreshNameTag()
        showVerdict("🥊 ОГРЕЛ!", color: .systemRed)
    }

    func beginGrab() {
        guard phase != .leaving, phase != .held, phase != .dropping else { return }
        cancelScan()
        resumePhase = phase
        phase = .held
        refreshNameTag()
        showVerdict("😬 ДЕРЖИСЬ!", color: .systemPurple)
    }

    func dropToFloor() {
        guard phase == .held else { return }
        knockDown(impulse:SIMD3(0,-0.6,0.5),accountable:false)
    }

    func ejectThroughDoor() {
        resumePhase = .leaving
        walkedInward = true
        showVerdict("🚪 ПОЛЁЛ ВОН!", color: .systemOrange)
    }

    func whackReaction() -> String {
        if isAggressive { return "😡 А ну отвали!" }
        if isDrunk { return "🥴 Ай, зачем бить?!" }
        if hasContraband { return "😨 Я ничего не делал!" }
        return "😟 Ты что, охрана?!"
    }

    func removeFromWorld() {
        root.removeFromParentNode()
    }
}

// MARK: - Игра

// Pure game rules also run in the portable regression suite.
struct SecurityShiftProgress {
    var decisions = 0
    var correct = 0
    var streak = 0
    var longestStreak = 0
    var accuracy: Int { decisions == 0 ? 0 : correct * 100 / decisions }
    mutating func record(correct value: Bool) -> Int {
        decisions += 1
        if value { correct += 1; streak += 1 } else { streak = 0 }
        longestStreak = max(longestStreak, streak)
        return value ? min(max(streak - 1, 0) * 10, 50) : 0
    }
    static func requiresInspection(wave: Int) -> Bool { wave % 3 == 2 }
    static func admits(contraband: Bool, drunk: Bool, aggressive: Bool, wave: Int) -> Bool {
        !contraband && !drunk && (wave % 3 != 0 || !aggressive)
    }
    static func rule(wave: Int) -> String {
        if wave % 3 == 2 { return "Полный досмотр\nСканер + алкотестер\nБез контрабанды и алкоголя" }
        if wave % 3 == 0 { return "Без агрессивных гостей\nБез скейтов и колонок\nБез контрабанды и алкоголя" }
        return "Без контрабанды и алкоголя\nЦепочки запрещены"
    }
}

final class SecurityVRGame {
    var onExitRequested: (() -> Void)?
    var onInteraction: (() -> Void)?

    private(set) var isRunning = false
    private weak var scene: SCNScene?
    private let root = SCNNode()

    private var money = 0
    private var score = 0
    private var wave = 1
    private var servedInWave = 0
    private var progress = SecurityShiftProgress()
    private var bestScore = UserDefaults.standard.integer(forKey: "securityVR.bestScore")
    private var paused = false

    private var guest: SecurityGuest?
    private var spawnCooldown: Double = 0.5
    private var walkSpeed: Float = 0.8
    private var contrabandChance: Float = 0.35
    private var drunkChance: Float = 0.30
    private var aggressiveChance: Float = 0.25

    private var inventory = SecurityInventory()
    private var goodsNodes: [UUID:SCNNode] = [:]
    private var goodsSlots: [UUID:Int] = [:]
    private var nodeGoods: [ObjectIdentifier:UUID] = [:]
    private var tradeFocus: UUID?
    private let tradeLabel = TextSprite()
    private let buyButton = SecurityButton(title:"КУПИТЬ",color:.systemTeal,hitRadius:0.22)
    private let sellButton = SecurityButton(title:"ПРОДАТЬ",color:.systemGreen,hitRadius:0.22)
    private let seizeButton = SecurityButton(title:"ИЗЪЯТЬ",color:.systemOrange,hitRadius:0.22)
    private var selectedTool: SecurityTool = .scanner

    private let moneyLabel = TextSprite()
    private let scoreLabel = TextSprite()
    private let waveLabel = TextSprite()
    private let hintLabel = TextSprite()
    private let toastLabel = TextSprite()
    private let toolLabel = TextSprite()
    private let rulesBoard = TextSprite()
    private let inspectionLabel = TextSprite()
    private let shiftLabel = TextSprite()

    private let acceptButton = SecurityButton(title: "✅ ВПУСТИТЬ", color: UIColor(red: 0.15, green: 0.70, blue: 0.32, alpha: 1))
    private let rejectButton = SecurityButton(title: "❌ ОТКАЗАТЬ", color: UIColor(red: 0.80, green: 0.16, blue: 0.22, alpha: 1))
    private let rulesButton = SecurityButton(title: "📜 ПРАВИЛА", color: UIColor(red: 0.35, green: 0.35, blue: 0.42, alpha: 1), hitRadius: 0.22, fontSize: 4.6)
    private let exitButton = SecurityButton(title: "🚪 ВЫХОД", color: UIColor(white: 0.25, alpha: 1), hitRadius: 0.22, fontSize: 4.6)
    private let pauseButton = SecurityButton(title: "Ⅱ / ▶ ПАУЗА", color: .darkGray, hitRadius: 0.22)
    private var toolButtons: [SecurityTool: SecurityButton] = [:]
    private var decisionButtons: [SecurityButton] { [acceptButton, rejectButton] }
    private var allButtons: [SecurityButton] {
        decisionButtons + [rulesButton, exitButton, pauseButton,buyButton,sellButton,seizeButton] + toolButtons.values.sorted { $0.node.position.x < $1.node.position.x }
    }

    private var rulesVisible = false
    private var effects: [(node: SCNNode, ttl: Float)] = []

    // Хват предметов и гостей
    private var pickables: [SCNNode] = []
    private var heldItem: SCNNode?
    private var heldGuest: SecurityGuest?
    private var heldGuestHand: SCNNode?
    private let myHand = MyHand()
    private var heldPrevWorld = SIMD3<Float>(0, 0, 0)
    private var heldVelocity = SIMD3<Float>(0, 0, 0)
    private var freeItems: [(node: SCNNode, velocity: SIMD3<Float>, spin: SIMD3<Float>)] = []
    private var heldPoseReady = false
    private var punchCooldown: Float = 0
    private let handDistance: Float = 0.45

    private var grabGate = GraffitiGrabGate()
    private(set) var inputHand: TrackedHand?
    private var inputGeneration: UInt64?
    private var previousPinch = false
    private var uiClickGate = ReleaseClickGate<ObjectIdentifier>()
    private var toolDwellGate = ReleaseClickGate<SecurityTool>()
    private let dwellRing = DwellProgressRing()
    private var lastFrameTime = CACurrentMediaTime()

    private static let guestNames = [
        "Игорь", "Артём", "Макс", "Рома", "Кирилл", "Олег",
        "Тимур", "Дэн", "Никита", "Юля", "Алина", "Марина",
        "Даша", "Ксюша", "Вика", "Соня"
    ]

    // MARK: Старт / стоп

    func start(in scene: SCNScene, cameraOrigin: SIMD3<Float>, cameraForward: SIMD3<Float>) {
        guard !isRunning else { return }
        uiClickGate.cancel()
        toolDwellGate.cancel()
        isRunning = true
        self.scene = scene

        let forward = simd_normalize(SIMD3<Float>(cameraForward.x, 0, cameraForward.z))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        // Пол комнаты всегда на 1.62 м ниже глаз — сцена заполняет кадр
        // независимо от того, где в AR-мировых координатах оказался ноль.
        root.simdPosition = simd_float3(
            cameraOrigin.x + forward.x * 1.0 + right.x * 0.35,
            cameraOrigin.y - 1.62,
            cameraOrigin.z + forward.z * 1.0 + right.z * 0.35
        )
        root.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward)

        // Перезапуск: чистим прошлую сессию, чтобы узлы не дублировались.
        root.childNodes.forEach { $0.removeFromParentNode() }
        pickables.removeAll()
        freeItems.removeAll()
        heldItem = nil
        heldGuest = nil
        heldGuestHand = nil
        punchCooldown = 0
        rulesVisible = false
        money = 120
        inventory = SecurityInventory(); goodsNodes.removeAll(); goodsSlots.removeAll(); nodeGoods.removeAll(); tradeFocus = nil
        score = 0
        wave = 1
        servedInWave = 0
        progress = SecurityShiftProgress()
        paused = false
        spawnCooldown = 0.5
        walkSpeed = 0.8
        contrabandChance = 0.35
        drunkChance = 0.30
        aggressiveChance = 0.25
        selectedTool = .scanner

        buildEnvironment()
        buildHUD()
        scene.rootNode.addChildNode(root)
        // Моя рука живёт в мировых координатах — добавляем к корню сцены.
        scene.rootNode.addChildNode(myHand.node)
        myHand.node.isHidden = true

        _ = grabGate.cancel()
        inputHand = nil; inputGeneration = nil
        previousPinch = false
        lastFrameTime = CACurrentMediaTime()
        toastLabel.setText("🛡 Пропускай гостей. 📜 ПРАВИЛА — справа. Кулак — взять, ладонь 2 с — отпустить")
        refreshHUD()
    }

    func stop() {
        uiClickGate.cancel()
        toolDwellGate.cancel()
        guard isRunning else { return }
        isRunning = false
        guest?.removeFromWorld()
        guest = nil
        heldItem = nil
        heldGuest = nil
        heldGuestHand = nil
        myHand.reset()
        inventory = SecurityInventory(); goodsNodes.removeAll(); goodsSlots.removeAll(); nodeGoods.removeAll(); tradeFocus = nil
        freeItems.removeAll()
        pickables.removeAll()
        effects.forEach { $0.node.removeFromParentNode() }
        effects.removeAll()
        root.removeFromParentNode()
        scene = nil
    }

    // MARK: Сцена

    private func buildEnvironment() {
        let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 700
        let fill = SCNNode(); fill.light = ambient; root.addChildNode(fill)
        let key = SCNLight(); key.type = .directional; key.intensity = 900; key.castsShadow = false
        let lamp = SCNNode(); lamp.light = key; lamp.eulerAngles = SCNVector3(-0.7,-0.5,0); root.addChildNode(lamp)
        let neonCyan = SCNMaterial()
        neonCyan.applyConstant(UIColor(red: 0.15, green: 0.85, blue: 1, alpha: 1), emissive: 0.8)
        let neonMagenta = SCNMaterial()
        neonMagenta.applyConstant(UIColor(red: 1, green: 0.25, blue: 0.75, alpha: 1), emissive: 0.8)
        let floorMaterial = SCNMaterial()
        floorMaterial.applyConstant(UIColor(red: 0.07, green: 0.08, blue: 0.14, alpha: 1))
        let wallMaterial = SCNMaterial()
        wallMaterial.applyConstant(UIColor(white: 0.06, alpha: 1))
        let ceilingMaterial = SCNMaterial()
        ceilingMaterial.applyConstant(UIColor(white: 0.03, alpha: 1))
        let gold = SCNMaterial()
        gold.applyConstant(UIColor(red: 0.85, green: 0.68, blue: 0.25, alpha: 1), emissive: 0.15)

        // Пол
        let floor = SCNBox(width: 7.2, height: 0.1, length: 7.4, chamferRadius: 0.02)
        floor.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -0.05, -0.4)
        root.addChildNode(floorNode)

        // Стены по периметру — игрок стоит внутри комнаты.
        let backWall = SCNBox(width: 7.2, height: 3.4, length: 0.1, chamferRadius: 0)
        backWall.materials = [wallMaterial]
        let backWallNode = SCNNode(geometry: backWall)
        backWallNode.position = SCNVector3(0, 1.7, -4.1)
        root.addChildNode(backWallNode)

        let behindWall = SCNBox(width: 7.2, height: 3.4, length: 0.1, chamferRadius: 0)
        behindWall.materials = [wallMaterial]
        let behindWallNode = SCNNode(geometry: behindWall)
        behindWallNode.position = SCNVector3(0, 1.7, 3.3)
        root.addChildNode(behindWallNode)

        let leftWall = SCNBox(width: 0.1, height: 3.4, length: 7.4, chamferRadius: 0)
        leftWall.materials = [wallMaterial]
        let leftWallNode = SCNNode(geometry: leftWall)
        leftWallNode.position = SCNVector3(-3.55, 1.7, -0.4)
        root.addChildNode(leftWallNode)

        let rightWall = SCNBox(width: 0.1, height: 3.4, length: 7.4, chamferRadius: 0)
        rightWall.materials = [wallMaterial]
        let rightWallNode = SCNNode(geometry: rightWall)
        rightWallNode.position = SCNVector3(3.55, 1.7, -0.4)
        root.addChildNode(rightWallNode)

        // Потолок — замкнутая комната на весь экран.
        let ceiling = SCNBox(width: 7.2, height: 0.1, length: 7.4, chamferRadius: 0)
        ceiling.materials = [ceilingMaterial]
        let ceilingNode = SCNNode(geometry: ceiling)
        ceilingNode.position = SCNVector3(0, 3.45, -0.4)
        root.addChildNode(ceilingNode)

        // Неоновая подсветка по периметру потолка.
        let stripLeft = SCNBox(width: 0.02, height: 0.06, length: 7.0, chamferRadius: 0)
        stripLeft.materials = [neonMagenta]
        let stripLeftNode = SCNNode(geometry: stripLeft)
        stripLeftNode.position = SCNVector3(-3.48, 3.1, -0.4)
        root.addChildNode(stripLeftNode)

        let stripRight = SCNBox(width: 0.02, height: 0.06, length: 7.0, chamferRadius: 0)
        stripRight.materials = [neonCyan]
        let stripRightNode = SCNNode(geometry: stripRight)
        stripRightNode.position = SCNVector3(3.48, 3.1, -0.4)
        root.addChildNode(stripRightNode)

        let stripBack = SCNBox(width: 6.8, height: 0.06, length: 0.02, chamferRadius: 0)
        stripBack.materials = [neonMagenta]
        let stripBackNode = SCNNode(geometry: stripBack)
        stripBackNode.position = SCNVector3(0, 3.1, -4.02)
        root.addChildNode(stripBackNode)

        // Вывеска — рисуем в картинку, масштаб подбирается по ширине.
        let signTop = TextSprite()
        signTop.setText("SECURITY", color: UIColor(red: 1, green: 0.25, blue: 0.75, alpha: 1))
        signTop.position = SCNVector3(0, 2.85, -3.88)
        signTop.fitWidth(3.0)
        root.addChildNode(signTop)

        // Подписи помещения
        let doorLabel = TextSprite()
        doorLabel.setText("🚪 В КЛУБ")
        doorLabel.position = SCNVector3(0, 2.16, -3.97)
        doorLabel.fitWidth(1.5)
        root.addChildNode(doorLabel)

        let detectorLabel = TextSprite()
        detectorLabel.setText("🔍 ДОСМОТР")
        detectorLabel.position = SCNVector3(0, 2.3, -3.74)
        detectorLabel.fitWidth(1.6)
        root.addChildNode(detectorLabel)

        let rugLabel = TextSprite()
        rugLabel.setText("🚶 ЖДИ ЗДЕСЬ")
        rugLabel.position = SCNVector3(0.95, 0.3, -2.5)
        rugLabel.fitWidth(1.1)
        root.addChildNode(rugLabel)

        // Дверь клуба
        let door = SCNBox(width: 1.1, height: 2.1, length: 0.08, chamferRadius: 0.02)
        let doorMaterial = SCNMaterial()
        doorMaterial.applyConstant(UIColor(red: 0.10, green: 0.06, blue: 0.16, alpha: 1))
        door.materials = [doorMaterial]
        let doorNode = SCNNode(geometry: door)
        doorNode.position = SCNVector3(0, 1.05, -4.02)
        root.addChildNode(doorNode)

        // Рамка металлодетектора
        let detectorPosts = SCNBox(width: 0.09, height: 2.0, length: 0.09, chamferRadius: 0.02)
        detectorPosts.materials = [gold]
        for side in [-1, 1] {
            let post = SCNNode(geometry: detectorPosts)
            post.position = SCNVector3(0.5 * Float(side), 1.0, -3.8)
            root.addChildNode(post)
        }
        let detectorTop = SCNBox(width: 1.1, height: 0.10, length: 0.12, chamferRadius: 0.02)
        detectorTop.materials = [gold]
        let detectorTopNode = SCNNode(geometry: detectorTop)
        detectorTopNode.position = SCNVector3(0, 2.05, -3.8)
        root.addChildNode(detectorTopNode)

        let detectorBeacon = SCNSphere(radius: 0.045)
        detectorBeacon.materials = [neonCyan]
        let beaconNode = SCNNode(geometry: detectorBeacon)
        beaconNode.position = SCNVector3(0, 2.13, -3.8)
        root.addChildNode(beaconNode)

        // Стойка охраны слева
        let desk = SCNBox(width: 1.5, height: 0.06, length: 0.6, chamferRadius: 0.01)
        let deskMaterial = SCNMaterial()
        deskMaterial.applyConstant(UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1))
        desk.materials = [deskMaterial]
        let deskNode = SCNNode(geometry: desk)
        deskNode.position = SCNVector3(-1.25, 0.78, 0.9)
        root.addChildNode(deskNode)

        let postBox = SCNBox(width: 0.05, height: 0.78, length: 0.05, chamferRadius: 0)
        postBox.materials = [deskMaterial]
        for (x, z) in [(-2.0, 0.6), (-0.5, 0.6), (-2.0, 1.2), (-0.5, 1.2)] {
            let leg = SCNNode(geometry: postBox)
            leg.position = SCNVector3(x, 0.39, z)
            root.addChildNode(leg)
        }

        let frame = SecurityModels.material(UIColor(white:0.14,alpha:1),metal:0.6)
        let wood = SecurityModels.material(UIColor(red:0.28,green:0.17,blue:0.10,alpha:1),rough:0.7)
        for x in [Float(-3.05),-2.05] {
            SecurityModels.box(root,SIMD3(0.035,2.5,0.035),SIMD3(x,1.25,-0.85),frame)
            SecurityModels.box(root,SIMD3(0.035,2.5,0.035),SIMD3(x,1.25,-0.35),frame)
        }
        for row in 0..<4 { SecurityModels.box(root,SIMD3(1.05,0.04,0.54),SIMD3(-2.55,0.20+Float(row)*0.62,-0.6),wood) }

        // Модельки инструментов на стойке
        buildToolProps(deskY: 0.85)

        // Ковёр-дорожка перед входом
        let rug = SCNBox(width: 0.9, height: 0.012, length: 2.6, chamferRadius: 0)
        let rugMaterial = SCNMaterial()
        rugMaterial.applyConstant(UIColor(red: 0.35, green: 0.09, blue: 0.09, alpha: 1))
        rug.materials = [rugMaterial]
        let rugNode = SCNNode(geometry: rug)
        rugNode.position = SCNVector3(0, 0.006, -2.9)
        root.addChildNode(rugNode)
    }

    private func buildToolProps(deskY: Float) {
        for index in 0..<5 {
            let node = SecurityModels.tool(index)
            node.simdPosition = SIMD3(-1.80+Float(index)*0.27,deskY+0.06,0.9)
            if index != 4 { node.eulerAngles.y = 0.25 }
            root.addChildNode(node); pickables.append(node)
        }
    }

    private func buildHUD() {
        for (index,button) in [buyButton,seizeButton,sellButton].enumerated() {
            button.node.position = SCNVector3(1.35,0.70-Float(index)*0.20,-0.8)
            button.node.scale = SCNVector3(0.6,0.6,0.6); button.node.isHidden = true; root.addChildNode(button.node)
        }
        tradeLabel.maximumWidth = 0.85; tradeLabel.position = SCNVector3(1.35,0.88,-0.8); root.addChildNode(tradeLabel)

        for label in [moneyLabel,scoreLabel,waveLabel,shiftLabel,toolLabel,inspectionLabel] { label.maximumWidth = 0.90 }
        hintLabel.maximumWidth = 1.1; toastLabel.maximumWidth = 1.1
        pauseButton.node.position = SCNVector3(1.35, 1.15, -0.8)
        pauseButton.node.scale = SCNVector3(0.60, 0.60, 0.60)
        root.addChildNode(pauseButton.node)
        inspectionLabel.position = SCNVector3(-1.3, 1.43, -0.65)
        inspectionLabel.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        root.addChildNode(inspectionLabel)
        shiftLabel.position = SCNVector3(0, 2.35, -1.7)
        shiftLabel.maximumWidth = 1.30
        shiftLabel.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        root.addChildNode(shiftLabel)
        // Верхний ряд — деньги/очки/волна
        moneyLabel.setText("💰 $0", color: UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1))
        moneyLabel.position = SCNVector3(-1.3, 1.90, -0.65)
        moneyLabel.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        root.addChildNode(moneyLabel)

        scoreLabel.setText("⭐ Очки: 0")
        scoreLabel.position = SCNVector3(-1.3, 1.66, -0.65)
        scoreLabel.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        root.addChildNode(scoreLabel)

        waveLabel.setText("👥 Волна 1")
        waveLabel.position = SCNVector3(-1.3, 1.55, -0.65)
        waveLabel.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        root.addChildNode(waveLabel)

        toolLabel.setText("🔧 Инструмент: 📡 СКАНЕР")
        toolLabel.position = SCNVector3(-1.3, 1.32, -0.65)
        toolLabel.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        root.addChildNode(toolLabel)

        // Низ: подсказка и тост — внизу, чтобы не закрывать гостя
        hintLabel.setText("🚪 Гость идёт к входу")
        hintLabel.position = SCNVector3(0, 0.73, -0.7)
        hintLabel.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        root.addChildNode(hintLabel)

        toastLabel.position = SCNVector3(0, 0.87, -0.7)
        toastLabel.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        root.addChildNode(toastLabel)

        // Кнопки инструментов — ряд над стойкой.
        for (index, tool) in SecurityTool.allCases.enumerated() {
            let button = SecurityButton(title: tool.title, color: tool.color, hitRadius: 0.22, fontSize: 4.4)
            button.node.position = SCNVector3(-1.75 + Float(index) * 0.33, 1.12, -0.65)
            button.node.scale = SCNVector3(0.60, 0.60, 0.60)
            root.addChildNode(button.node)
            toolButtons[tool] = button
        }
        refreshToolHighlight()

        // Кнопки решений
        acceptButton.node.position = SCNVector3(-0.34, 0.97, -0.7)
        acceptButton.node.scale = SCNVector3(0.65,0.65,0.65)
        root.addChildNode(acceptButton.node)
        rejectButton.node.position = SCNVector3(0.34, 0.97, -0.7)
        rejectButton.node.scale = SCNVector3(0.65,0.65,0.65)
        root.addChildNode(rejectButton.node)

        rulesButton.node.position = SCNVector3(1.35, 1.38, -0.8)
        rulesButton.node.scale = SCNVector3(0.60, 0.60, 0.60)
        root.addChildNode(rulesButton.node)

        exitButton.node.position = SCNVector3(1.35, 0.92, -0.8)
        exitButton.node.scale = SCNVector3(0.60, 0.60, 0.60)
        root.addChildNode(exitButton.node)

        // Доска правил — спрятана до нажатия.
        rulesBoard.setText(Self.rulesText)
        rulesBoard.position = SCNVector3(0, 1.8, -2.2)
        rulesBoard.scale = SCNVector3(0.0022, 0.0022, 0.0022)
        rulesBoard.isHidden = true
        root.addChildNode(rulesBoard)
    }

    private static let rulesText = """
    📜 ПРАВИЛА КЛУБА

    1. 📡 СКАНЕР — наведение на грудь:
    обыск контрабанды.
    2. 🫁 АЛКО — наведение на лицо:
    проверка на трезвость.
    3. 📦 С контрабандой и 🍺 пьяных
    в клуб не пускай.
    4. 👆 Короткий щипок по гостю —
    поговорить.
    5. 🤝 Поднеси свою кисть к его руке
    и кулак — схватит за руку.
    6. 🤾 Таскай туда-сюда. У двери 🚪
    открой ладонь на 2 с — отпустишь.
    7. 🥊 Быстрый замах кистью вплотную —
    удар (по мирным штраф).
    8. 💦 Водянка — агрессору в нос,
    ⚡ ШОКЕР оглушает (тоже штраф
    по мирным!).
    9. В режиме щипка своди пальцы для
    сканирования. В режиме удержания
    просто держи курсор на цели.
    10. Наведи на вещь гостя: справа появятся
    покупка и изъятие по правилам смены.
    Свои вещи хранятся на стеллаже слева;
    наведи на них, чтобы продать гостю.
    11. Бутылкой или предметом можно ударить
    или бросить. За мирного гостя — штраф.
    12. Каждые 5 решений — новая смена.
    Читай её правило над входом.
    Пауза и потеря руки останавливают игру.
    """

    private func refreshHUD() {
        if score > bestScore {
            bestScore = score
            UserDefaults.standard.set(bestScore, forKey: "securityVR.bestScore")
        }
        moneyLabel.setText("💰 $\(money)", color: UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1))
        scoreLabel.setText("⭐ \(score) · Рекорд \(bestScore)")
        waveLabel.setText("Смена \(wave) · \(servedInWave)/5 · Серия \(progress.streak) · \(progress.accuracy)%")
        shiftLabel.setText(SecurityShiftProgress.rule(wave: wave))
    }

    private func refreshInspection() {
        guard let guest else { inspectionLabel.setText("Ожидание гостя"); return }
        let body = guest.scanned ? (guest.hasContraband ? "ЗАПРЕТ" : "чисто") : "не проверен"
        let breath = guest.breathTested ? (guest.isDrunk ? "АЛКОГОЛЬ" : "трезвый") : "не проверен"
        inspectionLabel.setText("Сканер: \(body) · Алкотестер: \(breath)")
    }

    private func refreshToolHighlight() {
        for (tool, button) in toolButtons {
            button.setHighlight(tool == selectedTool)
        }
        toolLabel.setText("🔧 Инструмент: \(selectedTool.title)")
    }

    // MARK: Эффекты

    private func spawnFlash(at localPosition: SCNVector3, color: UIColor) {
        let sphere = SCNSphere(radius: 0.06)
        let material = SCNMaterial()
        material.applyConstant(color, emissive: 1)
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.position = localPosition
        root.addChildNode(node)
        effects.append((node: node, ttl: 0.35))
    }

    private func updateEffects(dt: Float) {
        guard !effects.isEmpty else { return }
        for index in stride(from: effects.count - 1, through: 0, by: -1) {
            var effect = effects[index]
            effect.ttl -= dt
            let scale = max(effect.ttl / 0.35, 0.01)
            effect.node.scale = SCNVector3(scale, scale, scale)
            if effect.ttl <= 0 {
                effect.node.removeFromParentNode()
                effects.remove(at: index)
            } else {
                effects[index] = effect
            }
        }
    }

    // MARK: Хват

    /// Моя кисть едет за настоящей рукой: положение берём из луча кончика пальца.
    private func updateMyHand(ray: WorldRay?, dt: Float, gripping: Bool) {
        guard let ray else {
            myHand.node.isHidden = true
            return
        }
        myHand.node.isHidden = heldItem != nil
        myHand.node.scale = SCNVector3(0.65,0.65,0.65)
        let target = ray.origin + ray.direction * handDistance
        myHand.update(targetWorld: target, direction: ray.direction, dt: dt, gripping: gripping)
    }

    /// Тянем предмет или (рука к руке) гостя туда-сюда за своей кистью.
    private func followHeld(ray: WorldRay?, dt: Float) {
        if let item = heldItem {
            guard let ray else { return }
            let across = simd_cross(ray.direction,SIMD3<Float>(0,1,0))
            let side = simd_length(across)>0.001 ? simd_normalize(across) : SIMD3<Float>(1,0,0)
            let anchor = ray.origin + ray.direction * handDistance
            let offset = side * Float(0.09) - SIMD3<Float>(0,0.10,0)
            let world = anchor + offset
            let local = root.convertPosition(SCNVector3(world.x, world.y, world.z), from: nil)
            item.position = local
            item.simdOrientation = simd_quatf(angle:0,axis:SIMD3(0,1,0))
            let previous = heldPrevWorld
            let hadPose = heldPoseReady
            let travel = simd_length(world-previous)
            heldVelocity = heldPoseReady && dt>0.001 && travel<0.25 ? (world-previous)/dt : .zero
            heldPoseReady = true; heldPrevWorld = world
            let from = root.convertPosition(SCNVector3(previous.x,previous.y,previous.z),from:nil).simd3
            let to = root.convertPosition(SCNVector3(world.x,world.y,world.z),from:nil).simd3
            if hadPose, dt>0.001 { impactGuest(from:from,to:to,velocity:(to-from)/dt) }
            return
        }
        guard let guest = heldGuest, let handNode = heldGuestHand else { return }
        guard let ray else { return }
        _ = dt
        // Приклеиваем его кисть к моему кулаку: тело едет следом.
        let world = ray.origin + ray.direction * handDistance
        let handNow = handNode.presentation.simdWorldPosition
        var position = guest.root.simdPosition
        let localTarget = root.convertPosition(SCNVector3(world.x,world.y,world.z),from:nil).simd3
        let localHand = root.convertPosition(SCNVector3(handNow.x,handNow.y,handNow.z),from:nil).simd3
        position += localTarget - localHand
        position.y = max(position.y, -0.12)
        guest.root.simdPosition = position
    }

    /// Подтверждённое отпускание: предмет летит по броску, гость падает на пол.
    private func releaseHold(cancelled: Bool = false) {
        _ = grabGate.cancel()
        if cancelled { heldVelocity = .zero }
        if let item = heldItem {
            heldPoseReady = false
            heldItem = nil
            let currentWorld = item.presentation.simdWorldPosition
            let base = root.convertPosition(
                SCNVector3(currentWorld.x, currentWorld.y, currentWorld.z),
                from: nil
            )
            let ahead = root.convertPosition(
                SCNVector3(
                    currentWorld.x + heldVelocity.x,
                    currentWorld.y + heldVelocity.y,
                    currentWorld.z + heldVelocity.z
                ),
                from: nil
            )
            var localVelocity = SIMD3<Float>(
                Float(ahead.x - base.x),
                Float(ahead.y - base.y),
                Float(ahead.z - base.z)
            )
            let speed = simd_length(localVelocity)
            if speed > 8 { localVelocity = localVelocity / speed * 8 }
            freeItems.append((node:item,velocity:localVelocity,spin:SIMD3(localVelocity.z*2,1,-localVelocity.x*2)))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        if let guest = heldGuest {
            heldGuest = nil
            heldGuestHand = nil
            if cancelled { guest.dropToFloor(); return }
            if guest.root.position.z < 0 {
                // Дотащил до половины комнаты со дверью — значит выкидывает.
                guest.ejectThroughDoor()
                guest.dropToFloor()
                if guest.resolved { toastLabel.setText("Гость выведен"); return }
                guest.resolved = true
                let correct = !SecurityShiftProgress.admits(contraband: guest.hasContraband, drunk: guest.isDrunk,
                                                           aggressive: guest.isAggressive, wave: guest.arrivalWave)
                score += progress.record(correct: correct)
                money += correct ? 35 : -20
                score += correct ? 50 : -60
                if guest.isAggressive && correct {
                    money += 15
                    score += 40
                }
                toastLabel.setText(correct ? "🚪 Нарушитель выведен! +$35" : "Отказал чистому гостю: -$20")
                refreshHUD()
                servedInWave += 1
                if servedInWave >= 5 { nextWave() }
            } else {
                guest.dropToFloor()
                toastLabel.setText("🫳 Отпустил гостя")
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// Удар кулаком: быстрый замах кистью вплотную к голове/груди.
    private func punchGuest(_ guest: SecurityGuest, at handWorld: SIMD3<Float>) {
        guard punchCooldown <= 0 else { return }
        let chest = guest.root.convertPosition(guest.chestLocalPoint(), to: nil).simd3
        let head = guest.root.convertPosition(guest.headLocalPoint(), to: nil).simd3
        let distance = min(simd_distance(chest, handWorld), simd_distance(head, handWorld))
        guard distance < 0.24 else { return }

        punchCooldown = 1.0
        let hitPoint = root.convertPosition(guest.chestLocalPoint(), from: guest.root)
        spawnFlash(at: hitPoint, color: .orange)
        guest.root.position.z = max(guest.root.position.z - 0.35, -3.6)
        if guest.isAggressive {
            // По агрессору удар работает как самозащита.
            score += 40
            money += 15
            toastLabel.setText("🥊 Удар по агрессору! +$15")
            guest.applyTaserOnPunch()
        } else {
            score -= 25
            money -= 5
            toastLabel.setText("🥊 Ударил гостя... штраф -$5")
            guest.showVerdict(guest.whackReaction(), color: .orange)
            guest.knockDown(impulse:SIMD3(0,0.8,-1.5))
        }
        refreshHUD()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    private func impactGuest(from a: SIMD3<Float>, to b: SIMD3<Float>, velocity: SIMD3<Float>) {
        guard let guest, guest.phase != .leaving, guest.phase != .held, guest.phase != .dropping, punchCooldown<=0 else { return }
        let speed = simd_length(velocity)
        guard speed>=0.9, speed<=9, simd_length(b-a)<0.5 else { return }
        let chest = guest.root.convertPosition(guest.chestLocalPoint(),to:root).simd3
        let head = guest.root.convertPosition(guest.headLocalPoint(),to:root).simd3
        let bodyHit = TimeMotionGeometry.segmentSphere(from:a,to:b,center:chest,radius:0.38) != nil
        let headHit = TimeMotionGeometry.segmentSphere(from:a,to:b,center:head,radius:0.29) != nil
        guard bodyHit || headHit else { return }
        punchCooldown = 0.8
        let justified = guest.isAggressive || guest.hasContraband
        money += justified ? 15 : -20; score += justified ? 40 : -50
        toastLabel.setText(justified ? "Попадание! Нарушитель остановлен +$15" : "Мирный гость: штраф $20")
        guest.knockDown(impulse:velocity*0.5+SIMD3(0,0.8,0))
        spawnFlash(at:SCNVector3(b.x,b.y,b.z),color:.systemOrange)
        refreshHUD(); onInteraction?(); UIImpactFeedbackGenerator(style:.heavy).impactOccurred()
    }

    private func itemHalf(_ node: SCNNode) -> SIMD3<Float> {
        guard let id = nodeGoods[ObjectIdentifier(node)], let kind = inventory.entries[id]?.kind else {
            if pickables.count>4 && node === pickables[4] { return SIMD3(0.04,0.16,0.04) }
            return SIMD3(0.06,0.09,0.12)
        }
        switch kind {
        case .chain: return SIMD3(0.15,0.17,0.03)
        case .camera: return SIMD3(0.13,0.10,0.13)
        case .skateboard: return SIMD3(0.12,0.35,0.10)
        case .headphones: return SIMD3(0.13,0.14,0.06)
        case .speaker: return SIMD3(0.13,0.20,0.08)
        case .sealedCase: return SIMD3(0.14,0.15,0.07)
        case .bottle: return SIMD3(0.04,0.16,0.04)
        }
    }

    private func updateFreeItems(dt: Float) {
        guard !freeItems.isEmpty, dt>0 else { return }
        let steps = min(12,max(1,Int(ceil(dt*120))))
        let step = min(dt,0.1)/Float(steps)
        for _ in 0..<steps {
            for index in stride(from:freeItems.count-1,through:0,by:-1) {
                var entry = freeItems[index]
                let previous = entry.node.simdPosition
                entry.velocity.y -= 9.8*step
                var position = previous+entry.velocity*step
                entry.node.simdEulerAngles += entry.spin*step
                let extent = GraffitiFlight.extent(half:itemHalf(entry.node),angles:entry.node.simdEulerAngles)
                let overDesk = position.x > -2.05 && position.x < -0.45 && position.z > 0.55 && position.z < 1.25
                var surface = (overDesk ? Float(0.81) : 0)+extent.y
                if position.x > -3.08 && position.x < -2.02 && position.z > -0.87 && position.z < -0.33 {
                    for row in 0..<4 {
                        let shelf = Float(0.22)+Float(row)*0.62+extent.y
                        if previous.y>=shelf-0.005 && position.y<=shelf { surface = max(surface,shelf) }
                    }
                }
                if position.y<=surface && entry.velocity.y<0 {
                    position.y = surface; entry.velocity.y = -entry.velocity.y*0.28
                    entry.velocity.x *= 0.65; entry.velocity.z *= 0.65; entry.spin *= 0.75
                    if simd_length(entry.velocity)<0.25 { entry.velocity = .zero; entry.spin = .zero }
                }
                if position.x < -3.4 { position.x = -3.4; entry.velocity.x = abs(entry.velocity.x)*0.4 }
                if position.x > 3.4 { position.x = 3.4; entry.velocity.x = -abs(entry.velocity.x)*0.4 }
                if position.z < -3.95 { position.z = -3.95; entry.velocity.z = abs(entry.velocity.z)*0.4 }
                if position.z > 3.2 { position.z = 3.2; entry.velocity.z = -abs(entry.velocity.z)*0.4 }
                entry.node.simdPosition = position
                impactGuest(from:previous,to:position,velocity:entry.velocity)
                if simd_length(entry.velocity)<0.05 { freeItems.remove(at:index) }
                else { freeItems[index] = entry }
            }
        }
    }

    private func updateTradeFocus(ray: WorldRay?) {
        let activeGuest = guest?.phase == .atGate || guest?.phase == .dropping
        if let ray, ![buyButton,sellButton,seizeButton].contains(where: { $0.hitTest(ray:ray) }) {
            let candidates = goodsNodes.compactMap { id,node -> (UUID,Float)? in
                guard !node.isHidden, let t = sphereHit(ray:ray,center:node.presentation.simdWorldPosition,radius:0.18) else { return nil }
                return (id,t)
            }
            let selected = heldItem.flatMap { nodeGoods[ObjectIdentifier($0)] } ?? candidates.min(by: { $0.1<$1.1 })?.0
            if let selected, selected != tradeFocus { tradeFocus = selected; uiClickGate.cancel() }
        }
        guard activeGuest, let id = tradeFocus, let entry = inventory.entries[id], let guest else {
            for button in [buyButton,sellButton,seizeButton] { button.node.isHidden = true }
            tradeLabel.setText("Наведи на вещь гостя · товары: \(inventory.count)/8")
            return
        }
        let offered = entry.holder == .guest(guest.id), owned = entry.holder == .player
        buyButton.node.isHidden = !offered || guest.phase != .atGate || entry.kind == .sealedCase
        seizeButton.node.isHidden = !offered || !entry.kind.forbidden(wave:guest.arrivalWave)
        sellButton.node.isHidden = !owned || guest.phase != .atGate
        let text = owned ? "\(entry.kind.title) · продать $\(entry.kind.sellPrice)" : "\(entry.kind.title) · купить $\(entry.kind.buyPrice)"
        tradeLabel.setText(text)
    }

    @discardableResult private func trade(_ button: SecurityButton) -> Bool {
        guard let guest, let id = tradeFocus, let entry = inventory.entries[id] else { return false }
        if button === sellButton {
            guard guest.phase == .atGate, goodsNodes[id] != nil, inventory.sell(id,money:&money) else { return false }
            goodsSlots.removeValue(forKey:id)
            if let node = goodsNodes.removeValue(forKey:id) {
                if heldItem === node { heldItem = nil; heldPoseReady = false; _ = grabGate.cancel() }
                freeItems.removeAll { $0.node === node }; pickables.removeAll { $0 === node }
                nodeGoods.removeValue(forKey:ObjectIdentifier(node)); node.removeFromParentNode()
            }
            toastLabel.setText("Продано: \(entry.kind.title) +$\(entry.kind.sellPrice)")
        } else {
            let confiscate = button === seizeButton
            guard let node = guest.goods[id]?.node,
                  (guest.phase == .atGate || confiscate && guest.phase == .dropping),
                  inventory.acquire(id,from:guest.id,wave:guest.arrivalWave,confiscate:confiscate,money:&money) else {
                toastLabel.setText("Проверь деньги, правила и свободные места (8)")
                return false
            }
            _ = guest.removeGoods(id)
            let slot = (0..<SecurityInventory.capacity).first { !goodsSlots.values.contains($0) } ?? 0
            goodsSlots[id] = slot
            let shelf: Float = 0.22+Float(slot/2)*0.62
            node.simdPosition = SIMD3(-2.78+Float(slot%2)*0.44,shelf+itemHalf(node).y,-0.6)
            node.simdEulerAngles = .zero; root.addChildNode(node); pickables.append(node)
            if confiscate { score += 25 }
            toastLabel.setText(confiscate ? "Изъято по правилам: \(entry.kind.title)" : "Куплено: \(entry.kind.title)")
        }
        tradeFocus = nil; refreshHUD(); refreshInspection(); updateTradeFocus(ray:nil)
        return true
    }

    // MARK: Ввод

    func cancelInput() {
        uiClickGate.cancel()
        toolDwellGate.cancel()
        dwellRing.isHidden=true
        _ = grabGate.cancel()
        inputHand = nil; inputGeneration = nil; tradeFocus = nil
        previousPinch = false
        myHand.resetMotion()
        if isRunning { releaseHold(cancelled: true); guest?.cancelScan() }
    }

    func update(ray: WorldRay?, pinch requestedPinch: Bool, allowBegin: Bool = true, dwell: Bool = false,
                fist: Bool? = nil, open: Bool = false, hand: TrackedHand? = nil, trackingGeneration: UInt64? = nil) {
        guard isRunning else { return }
        if inputHand != hand || inputGeneration != trackingGeneration { cancelInput() }
        inputHand = hand; inputGeneration = trackingGeneration
        let sticky = fist != nil
        let pinch = requestedPinch && (previousPinch || allowBegin)
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
        lastFrameTime = now

        let pinchPressed = pinch && !previousPinch
        let pinchReleased = !pinch && previousPinch
        previousPinch = pinch

        if ray == nil {
            cancelInput()
            myHand.node.isHidden = true
            hintLabel.setText("Пауза: наведи руку или контроллер обратно в зал")
            return
        }

        updateTradeFocus(ray:ray)

        // Подсветка наведением
        for button in allButtons {
            button.setHighlight(button === toolButtons[selectedTool])
        }
        if let ray {
            for button in allButtons where button.hitTest(ray: ray) {
                button.setHighlight(true)
                break
            }
        }

        let uiTarget = ray.flatMap { ray in allButtons.first { $0.hitTest(ray:ray) } }
        let committed=uiClickGate.update(target:uiTarget.map {ObjectIdentifier($0)},down:pinch,allowBegin:allowBegin,dwell:dwell,at:now)
        dwellRing.show(on:uiTarget?.node,progress:uiClickGate.dwellProgress)
        if let committed,
           let uiTarget, ObjectIdentifier(uiTarget) == committed {
            if let tool = toolButtons.first(where: {$0.1 === uiTarget})?.0 {
                selectedTool = tool
                refreshToolHighlight()
            } else if uiTarget === buyButton || uiTarget === seizeButton || uiTarget === sellButton {
                guard trade(uiTarget) else { return }
            } else if uiTarget === exitButton { onExitRequested?() }
            else if uiTarget === pauseButton {
                paused.toggle()
                releaseHold(cancelled: true)
                guest?.cancelScan()
            }
            else if uiTarget === rulesButton {
                releaseHold(cancelled:true)
                rulesVisible.toggle()
                rulesBoard.isHidden = !rulesVisible
            } else if paused || rulesVisible { return }
            else if guest?.phase == .atGate, uiTarget === acceptButton { decide(accept:true) }
            else if guest?.phase == .atGate, uiTarget === rejectButton { decide(accept:false) }
            else { return }
            onInteraction?()
            UIImpactFeedbackGenerator(style:.light).impactOccurred()
            return
        }
        if paused || rulesVisible {
            toolDwellGate.cancel()
            myHand.resetMotion()
            guest?.cancelScan()
            myHand.node.isHidden = true
            hintLabel.setText(paused ? "Пауза · нажми Ⅱ / ▶ для продолжения" : "Правила открыты · игра на паузе")
            return
        }
        updateGuest(dt: dt)
        updateEffects(dt: dt)
        updateMyHand(ray: ray, dt: dt, gripping: pinch)
        punchCooldown = max(punchCooldown - dt, 0)
        refreshInspection()


        // Попадания в гостя (мировые координаты — как у луча трекинга).
        var hitChest = false
        var hitFace = false
        var chestWorld = SCNVector3Zero
        var headWorld = SCNVector3Zero
        if let ray, let guest,
           guest.phase == .arriving || guest.phase == .atGate
            || guest.phase == .attacking || guest.phase == .stunned {
            chestWorld = guest.root.convertPosition(guest.chestLocalPoint(), to: nil)
            headWorld = guest.root.convertPosition(guest.headLocalPoint(), to: nil)
            hitChest = sphereHit(ray: ray, center: chestWorld.simd3, radius: 0.30) != nil
            hitFace = sphereHit(ray: ray, center: headWorld.simd3, radius: 0.24) != nil
        }

        // The same confirmed fist / two-second opening gate as the drawing and shooter games.
        var grabPressed = false
        if sticky, let ray {
            let itemTarget = pickables.firstIndex { sphereHit(ray:ray,center:$0.presentation.simdWorldPosition,radius:0.16) != nil }
            let point = ray.origin + ray.direction * handDistance
            let guestTarget = guest.flatMap { guest -> Bool? in
                guard guest.phase != .leaving, guest.phase != .held, guest.phase != .dropping else { return false }
                return guest.handTipNodes().contains { simd_distance($0.presentation.simdWorldPosition,point)<0.28 }
            } ?? false
            let target = guestTarget ? pickables.count : itemTarget
            let event = grabGate.update(target:target,fist:fist == true,open:open,reliable:true,blocked:uiTarget != nil,at:now)
            if case .began = event { grabPressed = true }
            if case .released = event { releaseHold() }
            if case .cancelled = event { releaseHold(cancelled:true) }
        } else if pinchReleased { releaseHold() }
        if pinch || sticky { followHeld(ray:ray,dt:dt) }
        updateFreeItems(dt: dt)

        if uiTarget != nil { guest?.cancelScan(); toolDwellGate.cancel(); return }

        // Удар кулаком: быстрый замах вплотную к гостю (не держа его).
        if (fist == true || !dwell), heldItem == nil, heldGuest == nil, myHand.worldSpeed > 1.8, let guest,
           guest.phase != .leaving, guest.phase != .held, guest.phase != .dropping {
            punchGuest(guest, at: myHand.worldPosition)
        }

        // Подсказка — чего можно подхватить.
        if heldItem == nil, heldGuest == nil, let ray {
            if pickables.first(where: {
                sphereHit(ray: ray, center: $0.presentation.simdWorldPosition, radius: 0.16) != nil
            }) != nil {
                hintLabel.setText("Кулак — взять предмет")
            } else if let guest, guest.phase != .leaving, guest.phase != .held,
                      guest.phase != .dropping {
                let myHandPoint = ray.origin + ray.direction * handDistance
                let nearHand = guest.handTipNodes().contains {
                    simd_distance($0.presentation.simdWorldPosition, myHandPoint) < 0.28
                }
                if nearHand {
                    hintLabel.setText("Кулак у кисти гостя — схватить")
                } else if myHand.worldSpeed > 1.8 {
                    hintLabel.setText("👇 Быстрый замах — удар кулаком")
                }
            }
        }

        // Удержание щипка — сканирование текущим инструментом.
        if (pinch || dwell), heldItem == nil, heldGuest == nil, let guest, guest.phase == .atGate {
            switch selectedTool {
            case .scanner where hitChest:
                if !guest.scanned { guest.beginScan(kind: .body) }
                guest.addScanProgress(dt * 0.62)
            case .breathalyzer where hitFace:
                if !guest.breathTested { guest.beginScan(kind: .face) }
                guest.addScanProgress(dt * 0.9)
            default:
                guest.cancelScan()
            }
        } else { guest?.cancelScan() }

        let actionable = guest != nil && (guest?.phase == .atGate || guest?.phase == .attacking)
            && (hitChest || hitFace) && (selectedTool == .waterPistol || selectedTool == .taser)
        let dwellAction = toolDwellGate.update(target: dwell && actionable ? selectedTool : nil,
                                             down: false, allowBegin: false, dwell: dwell, at: now) != nil
        guard pinchPressed || dwellAction || grabPressed else { return }

        if let ray {
            // Кисть к его кисти + щипок — хват «рука к руке».
            if (!sticky && pinchPressed || grabPressed), heldItem == nil, heldGuest == nil, let guest,
               guest.phase != .leaving, guest.phase != .held, guest.phase != .dropping {
                let myHandPoint = ray.origin + ray.direction * handDistance
                if let handNode = guest.handTipNodes().first(where: {
                    simd_distance($0.presentation.simdWorldPosition, myHandPoint) < 0.28
                }) {
                    heldGuest = guest
                    heldGuestHand = handNode
                    guest.beginGrab()
                    heldVelocity = .zero
                    hintLabel.setText("🤾 Схватил за руку! Таскай туда-сюда, у двери отпусти — выкину")
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    return
                }
            }

            // Предмет со стойки — подхватить (любым инструментом).
            if (!sticky && pinchPressed || grabPressed), heldItem == nil {
                if let item = pickables.first(where: {
                    sphereHit(ray: ray, center: $0.presentation.simdWorldPosition, radius: 0.16) != nil
                }) {
                    freeItems.removeAll { $0.node === item }
                    if let index = pickables.firstIndex(where: { $0 === item }), index<4 {
                        selectedTool = SecurityTool.allCases[index]; refreshToolHighlight()
                    }
                    heldItem = item
                    heldPoseReady = false
                    heldVelocity = .zero
                    heldPrevWorld = ray.origin + ray.direction * handDistance
                    hintLabel.setText("Открытая ладонь 2 с — отпустить")
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    return
                }
            }

            if let guest, guest.phase == .atGate || guest.phase == .attacking {

                // Действия по гостю выбранным инструментом.
                if hitChest || hitFace {
                    let localHit = root.convertPosition(
                        hitFace ? guest.headLocalPoint() : guest.chestLocalPoint(),
                        from: guest.root
                    )
                    switch selectedTool {
                    case .scanner:
                        // Короткий щипок — поговорить.
                        guest.showVerdict(guest.talkPhrase(), color: .white)
                        hintLabel.setText("Щипок на груди (удержание) — осмотр")
                    case .breathalyzer:
                        guest.showVerdict(guest.talkPhrase(), color: .white)
                    case .waterPistol:
                        spawnFlash(at: localHit, color: .systemBlue)
                        let wasAggressive = guest.isAggressive
                        guest.applyWater()
                        money += wasAggressive ? 25 : -10
                        toastLabel.setText(wasAggressive ? "💦 Облил агрессивного! +$25" : "💦 Облил мирного гостя. -$10")
                        refreshHUD()
                    case .taser:
                        spawnFlash(at: localHit, color: .systemYellow)
                        let wasAggressiveTaser = guest.isAggressive
                        guest.applyTaser()
                        if wasAggressiveTaser {
                            score += 60
                            money += 30
                            toastLabel.setText("⚡ Оглушил агрессивного! +$30")
                        } else {
                            score -= 50
                            money -= 50
                            toastLabel.setText("⚡ Оглушил мирного! Штраф -$50")
                        }
                        refreshHUD()
                    case .hand:
                        // Захват обработан выше — сюда не попадаем.
                        break
                    }
                    return
                }
            }
        }
    }

    // MARK: Логика

    private func updateGuest(dt: Float) {
        if guest == nil {
            spawnCooldown -= Double(dt)
            if spawnCooldown <= 0 {
                spawnGuest()
            }
            return
        }
        guard let guest else { return }
        guest.update(dt: dt)

        if guest.phase == .atGate, guest.arrived, heldItem == nil, heldGuest == nil {
            switch selectedTool {
            case .scanner: hintLabel.setText("📡 Наведи на грудь и удерживай · в режиме щипка сведи пальцы")
            case .breathalyzer: hintLabel.setText("🫁 Наведи на лицо и удерживай · в режиме щипка сведи пальцы")
            case .waterPistol: hintLabel.setText("💦 Щипок по гостю — брызнуть водой")
            case .taser: hintLabel.setText("⚡ Щипок по гостю — оглушить")
            case .hand: hintLabel.setText("Кулак у кисти гостя — схватить")
            }
        }

        // Агрессивный гость бежит к игроку, если никто не вмешался.
        if guest.phase == .attacking {
            hintLabel.setText("🚨 ОН НАПАЁТ! 💦 или ⚡!")
            if guest.root.position.z >= 0.70 {
                guest.wasHitByPlayer()
                money -= 70
                score -= 40
                toastLabel.setText("🤕 Он пробил оборону! -$70")
                refreshHUD()
            }
        }

        if !guest.resolved && ((guest.phase == .dropping && guest.knockdownCounts) || (guest.phase == .leaving && guest.subdued)) {
            guest.resolved = true
            let correct = guest.isAggressive || guest.hasContraband
            score += progress.record(correct:correct); servedInWave += 1
            if servedInWave>=5 { nextWave() }
            refreshHUD()
        }
        if guest.leftScene {
            inventory.discardGuest(guest.id)
            let retained = Set(inventory.entries.keys)
            goodsNodes = goodsNodes.filter { retained.contains($0.key) }
            nodeGoods = nodeGoods.filter { retained.contains($0.value) }
            tradeFocus = nil
            guest.removeFromWorld()
            self.guest = nil
            spawnCooldown = 1.0
        }
    }

    private func spawnGuest() {
        let contraband = Float.random(in: 0...1) < contrabandChance
        let drunk = Float.random(in: 0...1) < drunkChance
        let aggressive = !drunk && Float.random(in: 0...1) < aggressiveChance
        let newGuest = SecurityGuest(
            hasContraband: contraband,
            isDrunk: drunk,
            isAggressive: aggressive,
            speed: walkSpeed, wave:wave
        )
        newGuest.root.position = SCNVector3(.random(in: -0.15...0.15), 0, -3.9)
        root.addChildNode(newGuest.root)
        guest = newGuest
        for (id,item) in newGuest.goods {
            inventory.register(id,kind:item.kind,guest:newGuest.id)
            goodsNodes[id] = item.node; nodeGoods[ObjectIdentifier(item.node)] = id
        }
        newGuest.setName(Self.guestNames.randomElement() ?? "Гость")
        hintLabel.setText("🚪 Гость идёт к входу")
    }

    private func decide(accept: Bool) {
        guard let guest, guest.phase == .atGate, !guest.resolved else { return }
        if SecurityShiftProgress.requiresInspection(wave: wave), (!guest.scanned || !guest.breathTested) {
            toastLabel.setText("Сначала заверши сканирование груди и алкотестер")
            return
        }
        let clean = SecurityShiftProgress.admits(contraband: guest.hasContraband, drunk: guest.isDrunk,
                                                 aggressive: guest.isAggressive, wave: wave)
        guest.resolved = true
        let bonus = progress.record(correct: accept == clean)
        score += bonus
        if !accept, guest.isAggressive {
            guest.beginAttack()
            toastLabel.setText("😡 Он разозлился и бросился на тебя!")
            hintLabel.setText("🚨 ОН НАПАЁТ! 💦 или ⚡!")
            servedInWave += 1
            if servedInWave >= 5 { nextWave() }
            refreshHUD()
            return
        }
        if accept && clean {
            score += 100
            money += 20
            toastLabel.setText("✅ Пропустил чистого гостя +$20")
        } else if !accept && guest.hasContraband {
            score += 150
            money += 80
            toastLabel.setText("📦 Контрабанда: отказ +$80")
        } else if !accept && guest.isDrunk {
            score += 120
            money += 60
            toastLabel.setText("🍺 Пьяного развернул! +$60")
        } else if accept && guest.hasContraband {
            score -= 120
            money -= 40
            toastLabel.setText("🚫 Пропустил контрабанду! -$40")
        } else if accept && guest.isDrunk {
            score -= 90
            money -= 30
            toastLabel.setText("🥴 Пьяного в клуб! -$30")
        } else if accept && !clean {
            score -= 100
            money -= 30
            toastLabel.setText("🚫 Нарушил строгие правила: агрессивный в клубе. -$30")
        } else {
            score -= 60
            toastLabel.setText("❌ Отказал чистому гостю. -60")
        }
        guest.leave(accepted: accept)
        servedInWave += 1
        hintLabel.setText("")
        refreshHUD()
        if servedInWave >= 5 {
            nextWave()
        }
    }

    private func nextWave() {
        servedInWave = 0
        wave += 1
        walkSpeed = min(walkSpeed * 1.18, 2.0)
        contrabandChance = min(contrabandChance + 0.06, 0.7)
        drunkChance = min(drunkChance + 0.05, 0.6)
        aggressiveChance = min(aggressiveChance + 0.04, 0.55)
        toastLabel.setText("🔔 ВОЛНА \(wave): гости быстрее и хитрее")
        refreshHUD()
    }
}
