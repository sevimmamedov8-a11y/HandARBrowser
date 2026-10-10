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

// MARK: - Текстовая плашка (всегда к лицу)

private final class TextSprite: SCNNode {
    private var current = ""

    override init() {
        super.init()
        constraints = [SCNBillboardConstraint()]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ value: String, color: UIColor = .white) {
        guard value != current else { return }
        current = value
        let text = SCNText(string: value, extrusionDepth: 0.004)
        text.font = UIFont.systemFont(ofSize: 52, weight: .semibold)
        text.flatness = 0.15
        let material = SCNMaterial()
        material.applyConstant(color, emissive: 1)
        text.materials = [material]
        let (minBounds, maxBounds) = text.boundingBox
        let node = SCNNode(geometry: text)
        node.pivot = SCNMatrix4MakeTranslation(-(minBounds.x + maxBounds.x) / 2, -(minBounds.y + maxBounds.y) / 2, 0)
        childNodes.forEach { $0.removeFromParentNode() }
        addChildNode(node)
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

        let label = SCNText(string: title, extrusionDepth: 0.006)
        label.font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        label.flatness = 0.1
        let textMaterial = SCNMaterial()
        textMaterial.applyConstant(.white, emissive: 1)
        label.materials = [textMaterial]
        let (minBounds, maxBounds) = label.boundingBox
        let textNode = SCNNode(geometry: label)
        textNode.pivot = SCNMatrix4MakeTranslation(-(minBounds.x + maxBounds.x) / 2, -(minBounds.y + maxBounds.y) / 2, 0.01)
        plate.addChildNode(textNode)
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

// MARK: - Инструмент охраны

private enum SecurityTool: Int, CaseIterable {
    case scanner
    case breathalyzer
    case waterPistol
    case taser

    var title: String {
        switch self {
        case .scanner: return "СКАНЕР"
        case .breathalyzer: return "АЛКО"
        case .waterPistol: return "ВОДЯНКА"
        case .taser: return "ШОКЕР"
        }
    }

    var color: UIColor {
        switch self {
        case .scanner: return UIColor(red: 0.12, green: 0.55, blue: 0.95, alpha: 1)
        case .breathalyzer: return UIColor(red: 0.12, green: 0.75, blue: 0.45, alpha: 1)
        case .waterPistol: return UIColor(red: 0.15, green: 0.70, blue: 0.90, alpha: 1)
        case .taser: return UIColor(red: 0.95, green: 0.80, blue: 0.10, alpha: 1)
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
            let hand = SCNSphere(radius: 0.055)
            hand.materials = [skin]
            let handNode = SCNNode(geometry: hand)
            handNode.position = SCNVector3(0, -0.64, 0)
            pivot.addChildNode(armNode)
            pivot.addChildNode(handNode)
            root.addChildNode(pivot)
            armPivots.append(pivot)
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

        // Плашка над головой
        verdict.setText("...")
        verdict.position = SCNVector3(0, 1.85, 0)
        root.addChildNode(verdict)
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

    // MARK: Геометрия для попаданий

    func chestLocalPoint() -> SCNVector3 {
        SCNVector3(torso.position.x, torso.position.y + 0.08, torso.position.z)
    }

    func headLocalPoint() -> SCNVector3 {
        SCNVector3(0, 1.50, 0)
    }

    // MARK: Диалог

    func talkPhrase() -> String {
        if phase == .attacking { return "ВОТ ПОЛУЧИ!" }
        if isAggressive { return ["Не приставай!", "Чё смотришь?", "А ну отойди!"].randomElement()! }
        if isDrunk { return ["Мне ещё пять...", "Ты же охрана? Пусти-и!", "Я почти трезвый..."].randomElement()! }
        if hasContraband { return ["У меня ничего нет.", "Быстрее пропускай.", "Я опаздываю..."].randomElement()! }
        return ["Добрый вечер!", "Красная дорожка где?", "Пусти, я чистый."].randomElement()!
    }

    func reactToWater() -> String {
        isAggressive ? "БЛЯХА! МОКРЫЙ!" : "ФУ, ЧТО ТВОРИШЬ?!"
    }

    func reactToTaser() -> String {
        isAggressive ? "ААА! ХВАТИТ!" : "ЗА ЧТО?!"
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
        case .leaving:
            let direction: Float = walkedInward ? -1 : 1
            root.position.z += 1.15 * dt * direction
            swingLimbs(factor: 1.0)
            if root.position.z <= -3.2 || root.position.z >= 2.4 {
                leftScene = true
            }
        }
    }

    private func swingLimbs(factor: Float) {
        let gait: Float = isDrunk ? 1.9 : 2.6
        let swing = sin(walkClock * gait) * 0.9 * factor
        for (index, pivot) in legPivots.enumerated() {
            pivot.eulerAngles.x = index == 0 ? swing : -swing
        }
        for (index, pivot) in armPivots.enumerated() {
            pivot.eulerAngles.x = index == 0 ? -swing * 0.8 : swing * 0.8
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
            verdict.setText("Сканирую грудь...")
        } else {
            scanRing.position = SCNVector3(0, 1.50, 0.22)
            scanBar.position = SCNVector3(0, 1.66, 0.20)
            scanBar.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.35, green: 1.0, blue: 0.55, alpha: 1)
            verdict.setText("Дуй в алкотестер...")
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
                verdict.setText(hasContraband ? "ЗАПРЕТ!" : "ЧИСТО",
                                color: hasContraband ? .systemRed : .systemGreen)
            case .face:
                breathTested = true
                verdict.setText(isDrunk ? "ПЬЯНИЦА!" : "ТРЕЗВЫЙ",
                                color: isDrunk ? .systemOrange : .systemGreen)
            }
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
        showVerdict("ВОТ ПОЛУЧИ!", color: .systemRed)
    }

    func wasHitByPlayer() {
        phase = .leaving
        walkedInward = false
    }

    func leave(accepted: Bool) {
        phase = .leaving
        walkedInward = accepted
        verdict.setText(accepted ? "ВНУТРИ" : "ОТКАЗ", color: accepted ? .systemGreen : .systemOrange)
    }

    func removeFromWorld() {
        root.removeFromParentNode()
    }
}

// MARK: - Игра

final class SecurityVRGame {
    var onExitRequested: (() -> Void)?

    private(set) var isRunning = false
    private weak var scene: SCNScene?
    private let root = SCNNode()

    private var money = 0
    private var score = 0
    private var wave = 1
    private var servedInWave = 0

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

    private let acceptButton = SecurityButton(title: "ВПУСТИТЬ", color: UIColor(red: 0.15, green: 0.70, blue: 0.32, alpha: 1))
    private let rejectButton = SecurityButton(title: "ОТКАЗАТЬ", color: UIColor(red: 0.80, green: 0.16, blue: 0.22, alpha: 1))
    private let rulesButton = SecurityButton(title: "ПРАВИЛА", color: UIColor(red: 0.35, green: 0.35, blue: 0.42, alpha: 1), hitRadius: 0.22, fontSize: 4.6)
    private let exitButton = SecurityButton(title: "ВЫХОД", color: UIColor(white: 0.25, alpha: 1), hitRadius: 0.22, fontSize: 4.6)
    private var toolButtons: [SecurityTool: SecurityButton] = [:]
    private var decisionButtons: [SecurityButton] { [acceptButton, rejectButton] }
    private var allButtons: [SecurityButton] {
        decisionButtons + [rulesButton, exitButton] + toolButtons.values.sorted { $0.node.position.x < $1.node.position.x }
    }

    private var rulesVisible = false
    private var effects: [(node: SCNNode, ttl: Float)] = []

    private var previousPinch = false
    private var lastFrameTime = CACurrentMediaTime()

    // MARK: Старт / стоп

    func start(in scene: SCNScene, cameraOrigin: SIMD3<Float>, cameraForward: SIMD3<Float>) {
        guard !isRunning else { return }
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

        buildEnvironment()
        buildHUD()
        scene.rootNode.addChildNode(root)

        previousPinch = false
        lastFrameTime = CACurrentMediaTime()
        toastLabel.setText("Пропускай гостей. Правила — кнопка ПРАВИЛА")
        refreshHUD()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        guest?.removeFromWorld()
        guest = nil
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

        // Вывеска
        let signTop = SCNText(string: "SECURITY", extrusionDepth: 0.02)
        signTop.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        signTop.flatness = 0.1
        signTop.materials = [neonMagenta]
        let signTopNode = SCNNode(geometry: signTop)
        let (signMin, signMax) = signTop.boundingBox
        signTopNode.pivot = SCNMatrix4MakeTranslation(-(signMin.x + signMax.x) / 2, -(signMin.y + signMax.y) / 2, 0)
        signTopNode.position = SCNVector3(0, 2.35, -3.9)
        signTopNode.constraints = [SCNBillboardConstraint()]
        root.addChildNode(signTopNode)

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
        let scanner = SCNNode(geometry: scannerBody)
        scanner.position = SCNVector3(-1.75, deskY, 0.9)
        root.addChildNode(scanner)

        // Алкотестер
        let alco = SCNCylinder(radius: 0.02, height: 0.12)
        let alcoMat = SCNMaterial()
        alcoMat.applyConstant(UIColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1))
        alco.materials = [alcoMat]
        let alcoNode = SCNNode(geometry: alco)
        alcoNode.position = SCNVector3(-1.45, deskY + 0.03, 0.9)
        alcoNode.eulerAngles.z = 1.4
        root.addChildNode(alcoNode)

        // Водяной пистолет
        let waterBody = SCNBox(width: 0.14, height: 0.05, length: 0.04, chamferRadius: 0.01)
        let waterMat = SCNMaterial()
        waterMat.applyConstant(UIColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 1), emissive: 0.2)
        waterBody.materials = [waterMat]
        let water = SCNNode(geometry: waterBody)
        water.position = SCNVector3(-1.15, deskY, 0.9)
        root.addChildNode(water)

        // Электрошокер
        let taserBody = SCNBox(width: 0.10, height: 0.04, length: 0.035, chamferRadius: 0.008)
        let taserMat = SCNMaterial()
        taserMat.applyConstant(UIColor(red: 0.9, green: 0.75, blue: 0.1, alpha: 1), emissive: 0.25)
        taserBody.materials = [taserMat]
        let taser = SCNNode(geometry: taserBody)
        taser.position = SCNVector3(-0.85, deskY, 0.9)
        root.addChildNode(taser)
    }

    private func buildHUD() {
        // Верхний ряд
        moneyLabel.setText("$0", color: UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1))
        moneyLabel.position = SCNVector3(-1.15, 2.0, 0.35)
        moneyLabel.scale = SCNVector3(0.007, 0.007, 0.007)
        root.addChildNode(moneyLabel)

        scoreLabel.setText("Очки: 0")
        scoreLabel.position = SCNVector3(1.15, 2.0, 0.35)
        scoreLabel.scale = SCNVector3(0.0065, 0.0065, 0.0065)
        root.addChildNode(scoreLabel)

        waveLabel.setText("Волна 1")
        waveLabel.position = SCNVector3(0, 2.3, 0.2)
        waveLabel.scale = SCNVector3(0.006, 0.006, 0.006)
        root.addChildNode(waveLabel)

        hintLabel.setText("Гость идёт к входу")
        hintLabel.position = SCNVector3(0, 1.45, 0.55)
        hintLabel.scale = SCNVector3(0.0055, 0.0055, 0.0055)
        root.addChildNode(hintLabel)

        toastLabel.position = SCNVector3(0, 1.62, 0.35)
        toastLabel.scale = SCNVector3(0.0055, 0.0055, 0.0055)
        root.addChildNode(toastLabel)

        toolLabel.setText("Инструмент: СКАНЕР")
        toolLabel.position = SCNVector3(-0.9, 1.62, 0.75)
        toolLabel.scale = SCNVector3(0.005, 0.005, 0.005)
        root.addChildNode(toolLabel)

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
        rulesBoard.position = SCNVector3(0, 1.75, -2.2)
        rulesBoard.scale = SCNVector3(0.0032, 0.0032, 0.0032)
        rulesBoard.isHidden = true
        root.addChildNode(rulesBoard)
    }

    private static let rulesText = """
    ПРАВИЛА КЛУБА

    1. Щипок на груди со СКАНЕРОМ —
    ищи контрабанду.
    2. Щипок на лицо с АЛКО —
    проверяй на трезвость.
    3. Пьяных и с контрабандой —
    отказывай.
    4. Щипок по гостю с любой
    кнопкой — поговорить.
    5. Напали? ВОДЯНКА успокоит,
    ШОКЕР оглушит.
    6. Шокером по мирным — штраф!
    """

    private func refreshHUD() {
        moneyLabel.setText("$\(money)")
        scoreLabel.setText("Очки: \(score)")
        waveLabel.setText("Волна \(wave)")
    }

    private func refreshToolHighlight() {
        for (tool, button) in toolButtons {
            button.setHighlight(tool == selectedTool)
        }
        toolLabel.setText("Инструмент: \(selectedTool.title)")
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

    // MARK: Ввод

    func update(ray: WorldRay?, pinch: Bool) {
        guard isRunning else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
        lastFrameTime = now

        let pinchPressed = pinch && !previousPinch
        previousPinch = pinch

        updateGuest(dt: dt)
        updateEffects(dt: dt)

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

        // Попадания в гостя (мировые координаты — как у луча трекинга).
        var hitChest = false
        var hitFace = false
        var chestWorld = SCNVector3Zero
        var headWorld = SCNVector3Zero
        if let ray, let guest, guest.phase == .atGate || guest.phase == .attacking {
            chestWorld = guest.root.convertPosition(guest.chestLocalPoint(), to: nil)
            headWorld = guest.root.convertPosition(guest.headLocalPoint(), to: nil)
            hitChest = sphereHit(ray: ray, center: chestWorld.simd3, radius: 0.30) != nil
            hitFace = sphereHit(ray: ray, center: headWorld.simd3, radius: 0.24) != nil
        }

        // Удержание щипка — сканирование текущим инструментом.
        if pinch, let guest, guest.phase == .atGate {
            switch selectedTool {
            case .scanner where hitChest:
                if !guest.scanned { guest.beginScan(kind: .body) }
                guest.addScanProgress(dt * 0.62)
            case .breathalyzer where hitFace:
                if !guest.breathTested { guest.beginScan(kind: .face) }
                guest.addScanProgress(dt * 0.9)
            default:
                if hitChest || hitFace {
                    // удержание без сканирующего инструмента — ничего
                }
            }
        }

        guard pinchPressed else { return }

        if let ray {
            // Кнопки инструментов
            for (tool, button) in toolButtons where button.hitTest(ray: ray) {
                selectedTool = tool
                refreshToolHighlight()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            if exitButton.hitTest(ray: ray) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onExitRequested?()
                return
            }
            if rulesButton.hitTest(ray: ray) {
                rulesVisible.toggle()
                rulesBoard.isHidden = !rulesVisible
                toastLabel.setText(rulesVisible ? "Правила на экране. Ещё раз — скрыть." : "Правила скрыты")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }

            if let guest, guest.phase == .atGate || guest.phase == .attacking {
                if guest.phase == .atGate {
                    if acceptButton.hitTest(ray: ray) {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        decide(accept: true)
                        return
                    }
                    if rejectButton.hitTest(ray: ray) {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        decide(accept: false)
                        return
                    }
                }

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
                        toastLabel.setText(wasAggressive ? "Облил агрессивного! +$25" : "Облил мирного гостя. -$10")
                        refreshHUD()
                    case .taser:
                        spawnFlash(at: localHit, color: .systemYellow)
                        let wasAggressive = guest.isAggressive
                        guest.applyTaser()
                        if wasAggressive {
                            score += 60
                            money += 30
                            toastLabel.setText("Оглушил агрессивного! +$30")
                        } else {
                            score -= 50
                            money -= 50
                            toastLabel.setText("Оглушил мирного! Штраф -$50")
                        }
                        refreshHUD()
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

        if guest.phase == .atGate, guest.arrived {
            switch selectedTool {
            case .scanner: hintLabel.setText("Щипок на груди — осмотр. Голова — поговорить")
            case .breathalyzer: hintLabel.setText("Щипок на лицо — проверка на трезвость")
            case .waterPistol: hintLabel.setText("Щипок по гостю — брызнуть водой")
            case .taser: hintLabel.setText("Щипок по гостю — оглушить")
            }
        }

        // Агрессивный гость бежит к игроку, если никто не вмешался.
        if guest.phase == .attacking {
            hintLabel.setText("ОН НАПАЁТ! Водянка или шокер!")
            if guest.root.position.z >= 0.70 {
                guest.wasHitByPlayer()
                money -= 70
                score -= 40
                toastLabel.setText("Он пробил оборону! -$70")
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
        hintLabel.setText("Гость идёт к входу")
    }

    private func decide(accept: Bool) {
        guard let guest, guest.phase == .atGate else { return }

        if accept, guest.isAggressive && !guest.scanned {
            // Отказ агрессивному провоцирует нападение; пускать можно, но рискованно.
        }
        if !accept, guest.isAggressive {
            guest.beginAttack()
            toastLabel.setText("Он разозлился и бросился на тебя!")
            hintLabel.setText("ОН НАПАЁТ! Водянка или шокер!")
            servedInWave += 1
            if servedInWave >= 5 { nextWave() }
            return
        }

        let clean = !guest.hasContraband && !guest.isDrunk
        let correctDecision = (accept != clean)
        if accept && clean {
            score += 100
            money += 20
            toastLabel.setText("Пропустил чистого гостя +$20")
        } else if !accept && guest.hasContraband {
            score += 150
            money += 80
            toastLabel.setText("Изъял контрабанду! +$80")
        } else if !accept && guest.isDrunk {
            score += 120
            money += 60
            toastLabel.setText("Пьяного развернул! +$60")
        } else if accept && guest.hasContraband {
            score -= 120
            money -= 40
            toastLabel.setText("Пропустил контрабанду! -40")
        } else if accept && guest.isDrunk {
            score -= 90
            money -= 30
            toastLabel.setText("Пьяного в клуб! -30")
        } else {
            score -= 60
            toastLabel.setText("Отказал чистому гостю. -60")
        }
        _ = correctDecision
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
        toastLabel.setText("ВОЛНА \(wave): гости быстрее и хитрее")
        refreshHUD()
    }
}
