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

    func setText(_ value: String, color: UIColor = .white) {
        guard value != current else { return }
        current = value
        if let image = renderLabelImage(value, color: color, fontSize: 52) {
            plane.width = image.size.width
            plane.height = image.size.height
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
        sphereHit(
            ray: ray,
            center: node.presentation.simdWorldPosition,
            radius: hitRadius
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
    let hasContraband: Bool
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

    init(hasContraband: Bool, isDrunk: Bool, isAggressive: Bool, speed: Float) {
        self.hasContraband = hasContraband
        self.isDrunk = isDrunk
        self.isAggressive = isAggressive
        self.speed = speed
        buildBody()
        buildScanUI()
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
        return (skin, hair, shirt)
    }

    private func buildBody() {
        let (skin, hair, shirt) = bodyMaterials()

        // Ноги — повороты от бёдер.
        for side in [-1, 1] {
            let pivot = SCNNode()
            pivot.position = SCNVector3(0.11 * Float(side), 0.82, 0)
            let leg = SCNBox(width: 0.10, height: 0.78, length: 0.11, chamferRadius: 0.04)
            leg.materials = [shirt]
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

        // Пьяный держит бутылку.
        if isDrunk {
            let bottle = SCNCylinder(radius: 0.028, height: 0.22)
            let bottleMaterial = SCNMaterial()
            bottleMaterial.applyConstant(UIColor(red: 0.15, green: 0.45, blue: 0.12, alpha: 1), emissive: 0.25)
            bottle.materials = [bottleMaterial]
            bottleNode = SCNNode(geometry: bottle)
            bottleNode.position = SCNVector3(0.30, 0.62, 0.06)
            bottleNode.eulerAngles.z = 0.5
            root.addChildNode(bottleNode)
        }

        // Контрабанда — светящийся кубик за спиной.
        let cube = SCNBox(width: 0.075, height: 0.075, length: 0.05, chamferRadius: 0.012)
        let cubeMaterial = SCNMaterial()
        cubeMaterial.applyConstant(UIColor(red: 0.92, green: 0.12, blue: 0.14, alpha: 1), emissive: 0.9)
        cube.materials = [cubeMaterial]
        contrabandNode = SCNNode(geometry: cube)
        contrabandNode.simdOrientation = simd_quatf(angle: 0.7, axis: SIMD3<Float>(0.3, 1, 0.2))
        contrabandNode.position = SCNVector3(0.05, 1.12, -0.16)
        contrabandNode.isHidden = true
        root.addChildNode(contrabandNode)

        // Плашка и имя над головой
        verdict.setText("...")
        verdict.position = SCNVector3(0, 1.86, 0)
        verdict.scale = SCNVector3(0.0024, 0.0024, 0.0024)
        root.addChildNode(verdict)

        nameTag.setText("🙂 \(displayName)")
        nameTag.position = SCNVector3(0, 2.15, 0)
        nameTag.scale = SCNVector3(0.0022, 0.0022, 0.0022)
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
            dropVelocity -= 9.8 * dt
            root.position.y += dropVelocity * dt
            if root.position.y <= 0 {
                root.position.y = 0
                dropVelocity = 0
                phase = resumePhase
                refreshNameTag()
            }
            swingLimbs(factor: 0.5)
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
                contrabandNode.isHidden = !hasContraband
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
        phase = .stunned
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
        phase = .stunned
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
        phase = .dropping
        dropVelocity = -0.6
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
        if wave % 3 == 2 { return "Полный досмотр: сканер + алкотестер перед решением" }
        if wave % 3 == 0 { return "Строгая смена: агрессивных тоже не впускать" }
        return "Обычная смена: без контрабанды и алкоголя"
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
        decisionButtons + [rulesButton, exitButton, pauseButton] + toolButtons.values.sorted { $0.node.position.x < $1.node.position.x }
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
    private var freeItems: [(node: SCNNode, velocity: SIMD3<Float>)] = []
    private var punchCooldown: Float = 0
    private let handDistance: Float = 0.45

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
        money = 0
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

        previousPinch = false
        lastFrameTime = CACurrentMediaTime()
        toastLabel.setText("🛡 Пропускай гостей. 📜 ПРАВИЛА — кнопка сверху. ✋ РУКА — хватать")
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
        freeItems.removeAll()
        pickables.removeAll()
        effects.forEach { $0.node.removeFromParentNode() }
        effects.removeAll()
        root.removeFromParentNode()
        scene = nil
    }

    // MARK: Сцена

    private func buildEnvironment() {
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
        // Сканер
        let scannerBody = SCNBox(width: 0.12, height: 0.05, length: 0.03, chamferRadius: 0.008)
        let scannerMat = SCNMaterial()
        scannerMat.applyConstant(UIColor(white: 0.35, alpha: 1))
        scannerBody.materials = [scannerMat]
        addPickable(
            geometry: scannerBody,
            position: SCNVector3(-1.75, deskY, 0.9),
            emoji: "📡",
            labelHeight: 0.14
        )

        // Алкотестер
        let alco = SCNCylinder(radius: 0.02, height: 0.12)
        let alcoMat = SCNMaterial()
        alcoMat.applyConstant(UIColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1))
        alco.materials = [alcoMat]
        addPickable(
            geometry: alco,
            position: SCNVector3(-1.45, deskY, 0.9),
            eulerAngles: SCNVector3(0, 0, 1.4),
            emoji: "🫁",
            labelHeight: 0.15
        )

        // Водяной пистолет
        let waterBody = SCNBox(width: 0.14, height: 0.05, length: 0.04, chamferRadius: 0.01)
        let waterMat = SCNMaterial()
        waterMat.applyConstant(UIColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 1), emissive: 0.2)
        waterBody.materials = [waterMat]
        addPickable(
            geometry: waterBody,
            position: SCNVector3(-1.15, deskY, 0.9),
            emoji: "💦",
            labelHeight: 0.14
        )

        // Электрошокер
        let taserBody = SCNBox(width: 0.10, height: 0.04, length: 0.035, chamferRadius: 0.008)
        let taserMat = SCNMaterial()
        taserMat.applyConstant(UIColor(red: 0.9, green: 0.75, blue: 0.1, alpha: 1), emissive: 0.25)
        taserBody.materials = [taserMat]
        addPickable(
            geometry: taserBody,
            position: SCNVector3(-0.85, deskY, 0.9),
            emoji: "⚡",
            labelHeight: 0.13
        )

        // Бутылка на стойке — чисто чтобы швырнуть
        let bottleBody = SCNCylinder(radius: 0.03, height: 0.24)
        let bottleMat = SCNMaterial()
        bottleMat.applyConstant(UIColor(red: 0.15, green: 0.45, blue: 0.12, alpha: 1), emissive: 0.2)
        bottleBody.materials = [bottleMat]
        addPickable(
            geometry: bottleBody,
            position: SCNVector3(-0.65, deskY + 0.09, 1.02),
            emoji: "🍾",
            labelHeight: 0.17
        )
    }

    /// Предмет, который можно подхватить ✋ РУКОЙ. Внутри — моделька и эмодзи над ней.
    private func addPickable(
        geometry: SCNGeometry,
        position: SCNVector3,
        eulerAngles: SCNVector3 = SCNVector3Zero,
        emoji: String,
        labelHeight: Float
    ) {
        let holder = SCNNode()
        holder.position = position

        let body = SCNNode(geometry: geometry)
        body.eulerAngles = eulerAngles
        holder.addChildNode(body)

        let label = TextSprite()
        label.setText(emoji)
        label.scale = SCNVector3(0.0024, 0.0024, 0.0024)
        label.position = SCNVector3(0, labelHeight, 0)
        holder.addChildNode(label)

        root.addChildNode(holder)
        pickables.append(holder)
    }

    private func buildHUD() {
        pauseButton.node.position = SCNVector3(0, 2.4, -0.1)
        pauseButton.node.scale = SCNVector3(0.8, 0.8, 0.8)
        root.addChildNode(pauseButton.node)
        inspectionLabel.position = SCNVector3(0, 1.5, 0.2)
        inspectionLabel.scale = SCNVector3(0.0017, 0.0017, 0.0017)
        root.addChildNode(inspectionLabel)
        shiftLabel.position = SCNVector3(0, 2.65, -0.3)
        shiftLabel.scale = SCNVector3(0.0015, 0.0015, 0.0015)
        root.addChildNode(shiftLabel)
        // Верхний ряд — деньги/очки/волна
        moneyLabel.setText("💰 $0", color: UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1))
        moneyLabel.position = SCNVector3(-1.05, 1.92, 0.0)
        moneyLabel.scale = SCNVector3(0.0028, 0.0028, 0.0028)
        root.addChildNode(moneyLabel)

        scoreLabel.setText("⭐ Очки: 0")
        scoreLabel.position = SCNVector3(1.05, 1.92, 0.0)
        scoreLabel.scale = SCNVector3(0.0028, 0.0028, 0.0028)
        root.addChildNode(scoreLabel)

        waveLabel.setText("👥 Волна 1")
        waveLabel.position = SCNVector3(0, 2.12, -0.05)
        waveLabel.scale = SCNVector3(0.0026, 0.0026, 0.0026)
        root.addChildNode(waveLabel)

        toolLabel.setText("🔧 Инструмент: 📡 СКАНЕР")
        toolLabel.position = SCNVector3(0, 1.74, 0.05)
        toolLabel.scale = SCNVector3(0.0024, 0.0024, 0.0024)
        root.addChildNode(toolLabel)

        // Низ: подсказка и тост — внизу, чтобы не закрывать гостя
        hintLabel.setText("🚪 Гость идёт к входу")
        hintLabel.position = SCNVector3(0, 0.62, 0.6)
        hintLabel.scale = SCNVector3(0.0026, 0.0026, 0.0026)
        root.addChildNode(hintLabel)

        toastLabel.position = SCNVector3(0, 0.86, 0.5)
        toastLabel.scale = SCNVector3(0.0026, 0.0026, 0.0026)
        root.addChildNode(toastLabel)

        // Кнопки инструментов — ряд над стойкой.
        for (index, tool) in SecurityTool.allCases.enumerated() {
            let button = SecurityButton(title: tool.title, color: tool.color, hitRadius: 0.22, fontSize: 4.4)
            button.node.position = SCNVector3(-1.95 + Float(index) * 0.5, 1.28, 0.75)
            button.node.scale = SCNVector3(0.85, 0.85, 0.85)
            root.addChildNode(button.node)
            toolButtons[tool] = button
        }
        refreshToolHighlight()

        // Кнопки решений
        acceptButton.node.position = SCNVector3(-0.62, 1.05, 0.55)
        root.addChildNode(acceptButton.node)
        rejectButton.node.position = SCNVector3(0.62, 1.05, 0.55)
        root.addChildNode(rejectButton.node)

        rulesButton.node.position = SCNVector3(-1.5, 2.1, -0.1)
        rulesButton.node.scale = SCNVector3(0.8, 0.8, 0.8)
        root.addChildNode(rulesButton.node)

        exitButton.node.position = SCNVector3(1.5, 2.1, -0.1)
        exitButton.node.scale = SCNVector3(0.8, 0.8, 0.8)
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
    и щипок — схватит за руку.
    6. 🤾 Таскай туда-сюда. У двери 🚪
    отпусти — выкинешь на улицу.
    7. 🥊 Быстрый замах кистью вплотную —
    удар (по мирным штраф).
    8. 💦 Водянка — агрессору в нос,
    ⚡ ШОКЕР оглушает (тоже штраф
    по мирным!).
    9. В режиме щипка своди пальцы для
    сканирования. В режиме удержания
    просто держи курсор на цели.
    10. Каждые 5 решений — новая смена.
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
        myHand.node.isHidden = false
        let target = ray.origin + ray.direction * handDistance
        myHand.update(targetWorld: target, direction: ray.direction, dt: dt, gripping: gripping)
    }

    /// Тянем предмет или (рука к руке) гостя туда-сюда за своей кистью.
    private func followHeld(ray: WorldRay?, dt: Float) {
        if let item = heldItem {
            guard let ray else { return }
            let world = ray.origin + ray.direction * handDistance
            let local = root.convertPosition(SCNVector3(world.x, world.y, world.z), from: nil)
            item.position = local
            if dt > 0.001 {
                heldVelocity = (world - heldPrevWorld) / dt
            }
            heldPrevWorld = world
            return
        }
        guard let guest = heldGuest, let handNode = heldGuestHand else { return }
        guard let ray else { return }
        _ = dt
        // Приклеиваем его кисть к моему кулаку: тело едет следом.
        let world = ray.origin + ray.direction * handDistance
        let handNow = handNode.presentation.simdWorldPosition
        var position = guest.root.simdPosition
        position += world - handNow
        position.y = max(position.y, -0.12)
        guest.root.simdPosition = position
    }

    /// Отпустили щипок: предмет летит по броску, гость падает на пол.
    private func releaseHold(cancelled: Bool = false) {
        if cancelled { heldVelocity = .zero }
        if let item = heldItem {
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
            freeItems.append((node: item, velocity: localVelocity))
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
                let correct = !SecurityShiftProgress.admits(contraband: guest.hasContraband, drunk: guest.isDrunk,
                                                           aggressive: guest.isAggressive, wave: wave)
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
        }
        refreshHUD()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// Физика брошенных предметов: гравитация, отскок, пол и стойка.
    private func updateFreeItems(dt: Float) {
        guard !freeItems.isEmpty else { return }
        for index in stride(from: freeItems.count - 1, through: 0, by: -1) {
            var entry = freeItems[index]
            entry.velocity.y -= 9.8 * dt
            var position = entry.node.simdPosition
            position += entry.velocity * dt

            let overDesk = position.x > -2.05 && position.x < -0.45
                && position.z > 0.55 && position.z < 1.25
            let surface: Float = overDesk ? 0.84 : 0.06
            if position.y <= surface && entry.velocity.y < 0 {
                position.y = surface
                entry.velocity.y = -entry.velocity.y * 0.28
                entry.velocity.x *= 0.55
                entry.velocity.z *= 0.55
                if abs(entry.velocity.y) < 0.6 {
                    entry.velocity = SIMD3<Float>(0, 0, 0)
                }
            }

            // Стены комнаты
            if position.x < -3.4 { position.x = -3.4; entry.velocity.x = abs(entry.velocity.x) * 0.4 }
            if position.x > 3.4 { position.x = 3.4; entry.velocity.x = -abs(entry.velocity.x) * 0.4 }
            if position.z < -3.95 { position.z = -3.95; entry.velocity.z = abs(entry.velocity.z) * 0.4 }
            if position.z > 3.2 { position.z = 3.2; entry.velocity.z = -abs(entry.velocity.z) * 0.4 }

            entry.node.simdPosition = position
            if simd_length(entry.velocity) < 0.05 {
                freeItems.remove(at: index)
            } else {
                freeItems[index] = entry
            }
        }
    }

    // MARK: Ввод

    func cancelInput() {
        uiClickGate.cancel()
        toolDwellGate.cancel()
        dwellRing.isHidden=true
        previousPinch = false
        myHand.resetMotion()
        if isRunning { releaseHold(cancelled: true); guest?.cancelScan() }
    }

    func update(ray: WorldRay?, pinch requestedPinch: Bool, allowBegin: Bool = true, dwell: Bool = false) {
        guard isRunning else { return }
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
            } else if uiTarget === exitButton { onExitRequested?() }
            else if uiTarget === pauseButton {
                paused.toggle()
                releaseHold(cancelled: true)
                guest?.cancelScan()
            }
            else if uiTarget === rulesButton {
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
        if uiTarget != nil { guest?.cancelScan(); toolDwellGate.cancel(); return }

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

        // Хват: отпустили щипок или тащим предмет/гостя за лучом.
        if pinchReleased {
            releaseHold()
        }
        if pinch {
            followHeld(ray: ray, dt: dt)
        }
        updateFreeItems(dt: dt)

        // Удар кулаком: быстрый замах вплотную к гостю (не держа его).
        if !dwell, heldItem == nil, heldGuest == nil, myHand.worldSpeed > 1.8, let guest,
           guest.phase != .leaving, guest.phase != .held, guest.phase != .dropping {
            punchGuest(guest, at: myHand.worldPosition)
        }

        // Подсказка — чего можно подхватить.
        if heldItem == nil, heldGuest == nil, let ray {
            if pickables.first(where: {
                sphereHit(ray: ray, center: $0.presentation.simdWorldPosition, radius: 0.16) != nil
            }) != nil {
                hintLabel.setText("👇 Щипок — взять предмет")
            } else if let guest, guest.phase != .leaving, guest.phase != .held,
                      guest.phase != .dropping {
                let myHandPoint = ray.origin + ray.direction * handDistance
                let nearHand = guest.handTipNodes().contains {
                    simd_distance($0.presentation.simdWorldPosition, myHandPoint) < 0.28
                }
                if nearHand {
                    hintLabel.setText("👇 Кисть к его руке + щипок — схватить")
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
        guard pinchPressed || dwellAction else { return }

        if let ray {
            // Кисть к его кисти + щипок — хват «рука к руке».
            if heldItem == nil, heldGuest == nil, let guest,
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
            if heldItem == nil {
                if let item = pickables.first(where: {
                    sphereHit(ray: ray, center: $0.presentation.simdWorldPosition, radius: 0.16) != nil
                }) {
                    freeItems.removeAll { $0.node === item }
                    heldItem = item
                    heldVelocity = .zero
                    heldPrevWorld = ray.origin + ray.direction * handDistance
                    hintLabel.setText("🔓 Отпусти — уронишь или швырни")
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
            case .hand: hintLabel.setText("🤝 Кисть к его руке + щипок — схватить")
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

        if guest.leftScene {
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
            speed: walkSpeed
        )
        newGuest.root.position = SCNVector3(.random(in: -0.15...0.15), 0, -3.9)
        root.addChildNode(newGuest.root)
        guest = newGuest
        newGuest.setName(Self.guestNames.randomElement() ?? "Гость")
        hintLabel.setText("🚪 Гость идёт к входу")
    }

    private func decide(accept: Bool) {
        guard let guest, guest.phase == .atGate else { return }
        if SecurityShiftProgress.requiresInspection(wave: wave), (!guest.scanned || !guest.breathTested) {
            toastLabel.setText("Сначала заверши сканирование груди и алкотестер")
            return
        }
        let clean = SecurityShiftProgress.admits(contraband: guest.hasContraband, drunk: guest.isDrunk,
                                                 aggressive: guest.isAggressive, wave: wave)
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
            toastLabel.setText("📦 Изъял контрабанду! +$80")
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
