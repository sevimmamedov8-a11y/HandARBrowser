import SceneKit
import simd
import UIKit

// MARK: - РњРµР»РѕС‡Рё РґР»СЏ РјР°С‚РµСЂРёР°Р»РѕРІ

private extension SCNMaterial {
    /// Р РѕРІРЅС‹Р№ С†РІРµС‚ Р±РµР· РѕСЃРІРµС‰РµРЅРёСЏ вЂ” СЂР°Р±РѕС‚Р°РµС‚ РІ РїР°СЃСЃС‚СЂ-СЂРµР¶РёРјРµ СЃ РѕР±РѕРёРјРё РіР»Р°Р·Р°РјРё.
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

// MARK: - РџРµСЂРµСЃРµС‡РµРЅРёРµ Р»СѓС‡Р° СЃРѕ СЃС„РµСЂРѕР№

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

// MARK: - РўРµРєСЃС‚РѕРІР°СЏ РїР»Р°С€РєР° (РІСЃРµРіРґР° Рє Р»РёС†Сѓ)

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

// MARK: - 3D-РєРЅРѕРїРєР°

private final class SecurityButton {
    let node = SCNNode()
    let hitRadius: Float
    private let plate: SCNNode
    private let base: UIColor

    init(title: String, color: UIColor, hitRadius: Float = 0.26) {
        self.base = color
        self.hitRadius = hitRadius

        let box = SCNBox(width: 0.44, height: 0.17, length: 0.02, chamferRadius: 0.032)
        let material = SCNMaterial()
        material.applyConstant(color.withAlphaComponent(0.95))
        box.materials = [material]
        plate = SCNNode(geometry: box)
        node.addChildNode(plate)

        let label = SCNText(string: title, extrusionDepth: 0.006)
        label.font = UIFont.systemFont(ofSize: 5.2, weight: .bold)
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

// MARK: - Р“РѕСЃС‚СЊ (РїСЂРѕС†РµРґСѓСЂРЅС‹Р№ РїРµСЂСЃРѕРЅР°Р¶)

private enum GuestPhase {
    case arriving
    case atGate
    case leaving
}

private final class SecurityGuest {
    let root = SCNNode()
    private(set) var phase: GuestPhase = .arriving
    private(set) var arrived = false
    private(set) var leftScene = false
    let hasContraband: Bool
    private(set) var scanned = false

    private let speed: Float
    private var walkClock: Float = 1.7
    private let porchTarget: Float = 0.45

    private var torso = SCNNode()
    private var legPivots: [SCNNode] = []
    private var armPivots: [SCNNode] = []

    private var contrabandNode = SCNNode()
    private var scanRing = SCNNode()
    private var scanBar = SCNNode()
    private let verdict = TextSprite()

    private var scanProgress: Float = 0
    private var walkedInward = true

    init(hasContraband: Bool, speed: Float) {
        self.hasContraband = hasContraband
        self.speed = speed
        buildBody()
        buildScanUI()
    }

    private func bodyMaterials() -> (skin: SCNMaterial, hair: SCNMaterial, shirt: SCNMaterial) {
        let skin = SCNMaterial()
        skin.applyConstant(UIColor(
            red: .random(in: 0.55...0.95),
            green: .random(in: 0.45...0.85),
            blue: 0.72,
            alpha: 1
        ))
        let hair = SCNMaterial()
        hair.applyConstant(UIColor(
            red: .random(in: 0...0.4),
            green: .random(in: 0...0.3),
            blue: 0.05,
            alpha: 1
        ))
        let shirt = SCNMaterial()
        shirt.applyConstant(UIColor(
            red: .random(in: 0...0.65),
            green: .random(in: 0...0.6),
            blue: 0.0,
            alpha: 1
        ))
        return (skin, hair, shirt)
    }

    private func buildBody() {
        let (skin, hair, shirt) = bodyMaterials()

        // РќРѕРіРё вЂ” РїРѕРІРѕСЂРѕС‚С‹ РѕС‚ Р±С‘РґРµСЂ.
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

        // РўРѕСЂСЃ
        let body = SCNBox(width: 0.36, height: 0.50, length: 0.20, chamferRadius: 0.06)
        body.materials = [shirt]
        torso = SCNNode(geometry: body)
        torso.position = SCNVector3(0, 1.07, 0)
        root.addChildNode(torso)

        // Р СѓРєРё СЃ РєРёСЃС‚СЏРјРё
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

        // Р“РѕР»РѕРІР° + РІРѕР»РѕСЃС‹
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

        // РљРѕРЅС‚СЂР°Р±Р°РЅРґР° вЂ” СЃРІРµС‚СЏС‰РёР№СЃСЏ РєСѓР±РёРє Р·Р° СЃРїРёРЅРѕР№.
        let cube = SCNBox(width: 0.075, height: 0.075, length: 0.05, chamferRadius: 0.012)
        let cubeMaterial = SCNMaterial()
        cubeMaterial.applyConstant(UIColor(red: 0.92, green: 0.12, blue: 0.14, alpha: 1), emissive: 0.9)
        cube.materials = [cubeMaterial]
        contrabandNode = SCNNode(geometry: cube)
        contrabandNode.simdOrientation = simd_quatf(angle: 0.7, axis: SIMD3<Float>(0.3, 1, 0.2))
        contrabandNode.position = SCNVector3(0.05, 1.12, -0.16)
        contrabandNode.isHidden = true
        root.addChildNode(contrabandNode)

        // РџР»Р°С€РєР° СЂРµР·СѓР»СЊС‚Р°С‚Р° РЅР°Рґ РіРѕР»РѕРІРѕР№
        verdict.setText("вЂ¦")
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
        let swing = sin(walkClock * 2.6) * 0.9 * factor
        for (index, pivot) in legPivots.enumerated() {
            pivot.eulerAngles.x = CGFloat(index == 0 ? swing : -swing)
        }
        for (index, pivot) in armPivots.enumerated() {
            pivot.eulerAngles.x = CGFloat(index == 0 ? -swing * 0.8 : swing * 0.8)
        }
        torso.position.y = Float(1.07) + abs(sin(walkClock * 2.6)) * 0.02 * factor
    }

    func beginScan() {
        guard phase == .atGate, !scanned else { return }
        scanBar.isHidden = false
        scanRing.isHidden = false
        verdict.setText("РЎРєР°РЅРёСЂСѓСЋвЂ¦")
    }

    func addScanProgress(_ delta: Float) {
        guard !scanned else { return }
        scanProgress = min(scanProgress + delta, 1)
        scanBar.scale = SCNVector3(max(scanProgress, 0.001), 1, 1)
        if scanProgress >= 1 {
            scanned = true
            scanRing.isHidden = true
            scanBar.isHidden = true
            contrabandNode.isHidden = !hasContraband
            verdict.setText(hasContraband ? "Р—РђРџР Р•Рў!" : "Р§РРЎРўРћ",
                            color: hasContraband ? .systemRed : .systemGreen)
        }
    }

    func leave(accepted: Bool) {
        phase = .leaving
        walkedInward = accepted
        verdict.setText(accepted ? "Р’РќРЈРўР Р" : "РћРўРљРђР—", color: accepted ? .systemGreen : .systemOrange)
    }

    func torsoLocalPoint() -> SCNVector3 {
        SCNVector3(
            torso.position.x,
            torso.position.y + 0.08,
            torso.position.z
        )
    }

    func removeFromWorld() {
        root.removeFromParentNode()
    }
}

// MARK: - РРіСЂР°

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

    private let moneyLabel = TextSprite()
    private let scoreLabel = TextSprite()
    private let waveLabel = TextSprite()
    private let hintLabel = TextSprite()
    private let toastLabel = TextSprite()

    private let acceptButton = SecurityButton(title: "Р’РџРЈРЎРўРРўР¬", color: UIColor(red: 0.15, green: 0.70, blue: 0.32, alpha: 1))
    private let rejectButton = SecurityButton(title: "РћРўРљРђР—РђРўР¬", color: UIColor(red: 0.80, green: 0.16, blue: 0.22, alpha: 1))
    private let exitButton = SecurityButton(title: "Р’Р«РҐРћР”", color: UIColor(white: 0.25, alpha: 1))
    private var buttons: [SecurityButton] { [acceptButton, rejectButton, exitButton] }

    private var previousPinch = false
    private var lastFrameTime = CACurrentMediaTime()

    // MARK: РЎС‚Р°СЂС‚ / СЃС‚РѕРї

    func start(in scene: SCNScene, cameraOrigin: SIMD3<Float>, cameraForward: SIMD3<Float>) {
        guard !isRunning else { return }
        isRunning = true
        self.scene = scene

        let forward = simd_normalize(SIMD3<Float>(cameraForward.x, 0, cameraForward.z))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), forward))
        root.simdPosition = simd_float3(
            cameraOrigin.x + forward.x * 1.0 + right.x * 0.35,
            0,
            cameraOrigin.z + forward.z * 1.0 + right.z * 0.35
        )
        root.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: forward)

        buildEnvironment()
        buildHUD()
        scene.rootNode.addChildNode(root)

        previousPinch = false
        lastFrameTime = CACurrentMediaTime()
        toastLabel.setText("РџСЂРѕРІРµСЂСЏР№ РіРѕСЃС‚РµР№ Сѓ РІС…РѕРґР°")
        refreshHUD()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        guest?.removeFromWorld()
        guest = nil
        root.removeFromParentNode()
        scene = nil
    }

    // MARK: РЎС†РµРЅР°

    private func buildEnvironment() {
        let neonCyan = SCNMaterial()
        neonCyan.applyConstant(UIColor(red: 0.15, green: 0.85, blue: 1, alpha: 1), emissive: 0.8)
        let neonMagenta = SCNMaterial()
        neonMagenta.applyConstant(UIColor(red: 1, green: 0.25, blue: 0.75, alpha: 1), emissive: 0.8)
        let floorMaterial = SCNMaterial()
        floorMaterial.applyConstant(UIColor(red: 0.07, green: 0.08, blue: 0.14, alpha: 1))
        let wallMaterial = SCNMaterial()
        wallMaterial.applyConstant(UIColor(white: 0.06, alpha: 1))
        let gold = SCNMaterial()
        gold.applyConstant(UIColor(red: 0.85, green: 0.68, blue: 0.25, alpha: 1), emissive: 0.15)

        // РџРѕР»
        let floor = SCNBox(width: 6.5, height: 0.1, length: 7, chamferRadius: 0.02)
        floor.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floor)
        floorNode.position = SCNVector3(0, -0.05, -0.5)
        root.addChildNode(floorNode)

        // РЎС‚РµРЅС‹
        let backWall = SCNBox(width: 6.5, height: 3.4, length: 0.1, chamferRadius: 0)
        backWall.materials = [wallMaterial]
        let backWallNode = SCNNode(geometry: backWall)
        backWallNode.position = SCNVector3(0, 1.7, -1.0)
        root.addChildNode(backWallNode)

        let leftWall = SCNBox(width: 0.1, height: 3.4, length: 7, chamferRadius: 0)
        leftWall.materials = [wallMaterial]
        let leftWallNode = SCNNode(geometry: leftWall)
        leftWallNode.position = SCNVector3(-3.2, 1.7, -0.5)
        root.addChildNode(leftWallNode)

        let rightWall = SCNBox(width: 0.1, height: 3.4, length: 7, chamferRadius: 0)
        rightWall.materials = [wallMaterial]
        let rightWallNode = SCNNode(geometry: rightWall)
        rightWallNode.position = SCNVector3(3.2, 1.7, -0.5)
        root.addChildNode(rightWallNode)

        // РќРµРѕРЅРѕРІР°СЏ РїРѕРґСЃРІРµС‚РєР°
        let stripLeft = SCNBox(width: 0.02, height: 0.06, length: 6.4, chamferRadius: 0)
        stripLeft.materials = [neonMagenta]
        let stripLeftNode = SCNNode(geometry: stripLeft)
        stripLeftNode.position = SCNVector3(-3.1, 2.9, -0.5)
        root.addChildNode(stripLeftNode)

        let stripRight = SCNBox(width: 0.02, height: 0.06, length: 6.4, chamferRadius: 0)
        stripRight.materials = [neonCyan]
        let stripRightNode = SCNNode(geometry: stripRight)
        stripRightNode.position = SCNVector3(3.1, 2.9, -0.5)
        root.addChildNode(stripRightNode)

        // Р’С‹РІРµСЃРєР°
        let signTop = SCNText(string: "SECURITY", extrusionDepth: 0.02)
        signTop.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        signTop.flatness = 0.1
        signTop.materials = [neonMagenta]
        let signTopNode = SCNNode(geometry: signTop)
        let (signMin, signMax) = signTop.boundingBox
        signTopNode.pivot = SCNMatrix4MakeTranslation(-(signMin.x + signMax.x) / 2, -(signMin.y + signMax.y) / 2, 0)
        signTopNode.position = SCNVector3(0, 2.35, -0.92)
        signTopNode.constraints = [SCNBillboardConstraint()]
        root.addChildNode(signTopNode)

        // Р”РІРµСЂСЊ РєР»СѓР±Р°
        let door = SCNBox(width: 1.1, height: 2.1, length: 0.08, chamferRadius: 0.02)
        let doorMaterial = SCNMaterial()
        doorMaterial.applyConstant(UIColor(red: 0.10, green: 0.06, blue: 0.16, alpha: 1))
        door.materials = [doorMaterial]
        let doorNode = SCNNode(geometry: door)
        doorNode.position = SCNVector3(0, 1.05, -0.96)
        root.addChildNode(doorNode)

        // Р Р°РјРєР° РјРµС‚Р°Р»Р»РѕРґРµС‚РµРєС‚РѕСЂР°
        let detectorPosts = SCNBox(width: 0.09, height: 2.0, length: 0.09, chamferRadius: 0.02)
        detectorPosts.materials = [gold]
        for side in [-1, 1] {
            let post = SCNNode(geometry: detectorPosts)
            post.position = SCNVector3(0.5 * Float(side), 1.0, -0.75)
            root.addChildNode(post)
        }
        let detectorTop = SCNBox(width: 1.1, height: 0.10, length: 0.12, chamferRadius: 0.02)
        detectorTop.materials = [gold]
        let detectorTopNode = SCNNode(geometry: detectorTop)
        detectorTopNode.position = SCNVector3(0, 2.05, -0.75)
        root.addChildNode(detectorTopNode)

        let detectorBeacon = SCNSphere(radius: 0.045)
        detectorBeacon.materials = [neonCyan]
        let beaconNode = SCNNode(geometry: detectorBeacon)
        beaconNode.position = SCNVector3(0, 2.13, -0.75)
        root.addChildNode(beaconNode)

        // РўСѓСЂРЅРёРєРµС‚-СЃС‚РѕР№РєР° РѕС…СЂР°РЅС‹ (СЃР»РµРІР° РѕС‚ РёРіСЂРѕРєР°)
        let desk = SCNBox(width: 1.5, height: 0.06, length: 0.6, chamferRadius: 0.01)
        let deskMaterial = SCNMaterial()
        deskMaterial.applyConstant(UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1))
        desk.materials = [deskMaterial]
        let deskNode = SCNNode(geometry: desk)
        deskNode.position = SCNVector3(-1.25, 0.78, 0.9)
        root.addChildNode(deskNode)

        for (x, z) in [(-2.0, 0.6), (-0.5, 0.6), (-2.0, 1.2), (-0.5, 1.2)] {
            let postBox = SCNBox(width: 0.05, height: 0.78, length: 0.05, chamferRadius: 0)
            postBox.materials = [deskMaterial]
            let leg = SCNNode(geometry: postBox)
            leg.position = SCNVector3(x, 0.39, z)
            root.addChildNode(leg)
        }

        // РљРѕРІС‘СЂ-РґРѕСЂРѕР¶РєР° РїРµСЂРµРґ РІС…РѕРґРѕРј
        let rug = SCNBox(width: 0.9, height: 0.012, length: 2.4, chamferRadius: 0)
        let rugMaterial = SCNMaterial()
        rugMaterial.applyConstant(UIColor(red: 0.35, green: 0.09, blue: 0.09, alpha: 1))
        rug.materials = [rugMaterial]
        let rugNode = SCNNode(geometry: rug)
        rugNode.position = SCNVector3(0, 0.006, -0.1)
        root.addChildNode(rugNode)
    }

    private func buildHUD() {
        // Р’РµСЂС…РЅРёР№ СЂСЏРґ
        moneyLabel.setText("$0", color: UIColor(red: 1, green: 0.82, blue: 0.25, alpha: 1))
        moneyLabel.position = SCNVector3(-1.15, 1.85, 0.35)
        moneyLabel.scale = SCNVector3(0.007, 0.007, 0.007)
        root.addChildNode(moneyLabel)

        scoreLabel.setText("РћС‡РєРё: 0")
        scoreLabel.position = SCNVector3(1.15, 1.85, 0.35)
        scoreLabel.scale = SCNVector3(0.0065, 0.0065, 0.0065)
        root.addChildNode(scoreLabel)

        waveLabel.setText("Р’РѕР»РЅР° 1")
        waveLabel.position = SCNVector3(0, 2.15, 0.2)
        waveLabel.scale = SCNVector3(0.006, 0.006, 0.006)
        root.addChildNode(waveLabel)

        hintLabel.setText("Р“РѕСЃС‚СЊ РёРґС‘С‚ РєРѕ РІС…РѕРґСѓ")
        hintLabel.position = SCNVector3(0, 1.45, 0.55)
        hintLabel.scale = SCNVector3(0.0055, 0.0055, 0.0055)
        root.addChildNode(hintLabel)

        toastLabel.position = SCNVector3(0, 1.62, 0.35)
        toastLabel.scale = SCNVector3(0.0055, 0.0055, 0.0055)
        root.addChildNode(toastLabel)

        // РљРЅРѕРїРєРё СЂРµС€РµРЅРёР№
        acceptButton.node.position = SCNVector3(-0.62, 1.05, 0.55)
        root.addChildNode(acceptButton.node)
        rejectButton.node.position = SCNVector3(0.62, 1.05, 0.55)
        root.addChildNode(rejectButton.node)

        exitButton.node.position = SCNVector3(1.45, 2.0, -0.3)
        exitButton.node.scale = SCNVector3(0.8, 0.8, 0.8)
        root.addChildNode(exitButton.node)
    }

    private func refreshHUD() {
        moneyLabel.setText("$\(money)")
        scoreLabel.setText("РћС‡РєРё: \(score)")
        waveLabel.setText("Р’РѕР»РЅР° \(wave)")
    }

    // MARK: Р’РІРѕРґ

    func update(ray: WorldRay?, pinch: Bool) {
        guard isRunning else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 0), 0.1))
        lastFrameTime = now

        let pinchPressed = pinch && !previousPinch
        previousPinch = pinch

        updateGuest(dt: dt)

        // РџРѕРґСЃРІРµС‚РєР° РЅР°РІРµРґРµРЅРёРµРј
        for button in buttons {
            button.setHighlight(false)
        }
        if let ray {
            for button in buttons where button.hitTest(ray: ray) {
                button.setHighlight(true)
                break
            }
        }

        // РЈРґРµСЂР¶Р°РЅРёРµ РЅР° РіСЂСѓРґРё РіРѕСЃС‚СЏ = СЃРєР°РЅРµСЂ
        var holdingGuest = false
        if let ray, let guest, pinch, guest.phase == .atGate {
            let chestLocal = guest.torsoLocalPoint()
            let chest = root.convertPosition(chestLocal, from: guest.root)
            if sphereHit(ray: ray, center: chest.simd3, radius: 0.32) != nil {
                holdingGuest = true
                if !guest.scanned { guest.beginScan() }
                guest.addScanProgress(dt * 0.62)
            }
        }

        guard pinchPressed else { return }

        if let ray {
            if exitButton.hitTest(ray: ray) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onExitRequested?()
                return
            }
            if let guest, guest.phase == .atGate {
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
        }
        if holdingGuest {
            guest?.beginScan()
        }
    }

    // MARK: Р›РѕРіРёРєР°

    private func updateGuest(dt: Float) {
        if guest == nil {
            spawnCooldown -= Double(dt)
            if spawnCooldown <= 0 {
                spawnGuest()
            }
            return
        }
        guest?.update(dt: dt)
        if let guest, guest.phase == .atGate, guest.arrived {
            hintLabel.setText("РЈРґРµСЂР¶РёРІР°Р№ С‰РёРїРѕРє РЅР° РіСЂСѓРґРё вЂ” РѕСЃРјРѕС‚СЂ")
        }
        if let guest, guest.leftScene {
            guest.removeFromWorld()
            self.guest = nil
            spawnCooldown = 1.0
        }
    }

    private func spawnGuest() {
        let contraband = Float.random(in: 0...1) < contrabandChance
        let newGuest = SecurityGuest(hasContraband: contraband, speed: walkSpeed)
        newGuest.root.position = SCNVector3(.random(in: -0.15...0.15), 0, -2.6)
        root.addChildNode(newGuest.root)
        guest = newGuest
        hintLabel.setText("Р“РѕСЃС‚СЊ РёРґС‘С‚ РєРѕ РІС…РѕРґСѓ")
    }

    private func decide(accept: Bool) {
        guard let guest, guest.phase == .atGate else { return }
        let correctDecision = (accept != guest.hasContraband)
        if correctDecision {
            score += guest.hasContraband ? 150 : 100
            money += guest.hasContraband ? 80 : 20
            toastLabel.setText(guest.hasContraband
                ? "РР·СЉСЏР» РєРѕРЅС‚СЂР°Р±Р°РЅРґСѓ! +$80"
                : "Р’РїСѓСЃС‚РёР» С‡РёСЃС‚РѕРіРѕ РіРѕСЃС‚СЏ +$20")
        } else {
            score -= accept ? 120 : 60
            toastLabel.setText(accept
                ? "РџСЂРѕРїСѓСЃС‚РёР» РєРѕРЅС‚СЂР°Р±Р°РЅРґСѓ! -120"
                : "РћС‚РєР°Р·Р°Р» С‡РёСЃС‚РѕРјСѓ РіРѕСЃС‚СЋ. -60")
        }
        guest.leave(accepted: accept)
        servedInWave += 1
        hintLabel.setText("")
        refreshHUD()
        if servedInWave >= 4 {
            nextWave()
        }
    }

    private func nextWave() {
        servedInWave = 0
        wave += 1
        walkSpeed = min(walkSpeed * 1.18, 2.0)
        contrabandChance = min(contrabandChance + 0.07, 0.75)
        toastLabel.setText("Р’РћР›РќРђ \(wave): РіРѕСЃС‚Рё Р±С‹СЃС‚СЂРµРµ Рё С…РёС‚СЂРµРµ")
        refreshHUD()
    }
}
