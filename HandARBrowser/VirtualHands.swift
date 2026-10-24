import Foundation

/// The camera supplies 2D landmarks, not measured finger depth. Projected points
/// form a shallow, solid glove; missing landmarks never reuse an old finger.
struct VirtualHandPose {
    let points: [SIMD3<Float>?]
    let center: SIMD3<Float>
    let across: SIMD3<Float>
    let along: SIMD3<Float>
    let normal: SIMD3<Float>
    let width: Float
    let length: Float

    static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x + a.y*b.y + a.z*b.z }
    static func length(_ v: SIMD3<Float>) -> Float { sqrt(dot(v, v)) }
    static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x)
    }
    static func fresh(_ timestamp: Double, at time: Double) -> Bool {
        timestamp.isFinite && time.isFinite && time >= timestamp && time-timestamp <= 0.12
    }

    init?(points: [SIMD3<Float>?], camera: SIMD3<Float>) {
        guard points.count == 21, camera.x.isFinite, camera.y.isFinite, camera.z.isFinite else { return nil }
        let points = points.map { p -> SIMD3<Float>? in
            guard let p, p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
            return p
        }
        guard let wrist = points[0], let index = points[5], let middle = points[9], let little = points[17] else { return nil }
        let length = Self.length(middle-wrist), width = Self.length(index-little)
        guard (0.025...0.18).contains(length), (0.015...0.14).contains(width) else { return nil }
        let along = (middle-wrist)/length
        let lateral = index-little-along*Self.dot(index-little, along)
        let lateralLength = Self.length(lateral)
        guard lateralLength > width*0.25 else { return nil }
        var across = lateral/lateralLength
        var normal = Self.cross(across, along)
        let center = (wrist+middle)*0.5
        if Self.dot(normal, camera-center) < 0 { across = -across; normal = -normal }
        self.points = points; self.center = center; self.across = across
        self.along = along; self.normal = normal; self.width = width; self.length = length
    }

    func segment(finger: Int, joint: Int) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard (0..<5).contains(finger), (0..<3).contains(joint) else { return nil }
        let start = 1+finger*4+joint
        guard let a = points[start], let b = points[start+1] else { return nil }
        let distance = Self.length(b-a)
        guard distance > 0.002, distance < length*1.2,
              Self.length(a-center) < length*2.7, Self.length(b-center) < length*2.7 else { return nil }
        return (a, b)
    }

    static func canOffset(distance: Float, left: Bool, right: SIMD3<Float>, up: SIMD3<Float>) -> SIMD3<Float> {
        // Fixed angular separation from the paint ray, including near the face.
        let distance = max(0.25, min(0.85, distance))
        return right * (distance * (left ? -0.28 : 0.28)) - up * (distance * 0.16)
    }
}

#if canImport(SceneKit) && canImport(UIKit)
import SceneKit
import UIKit
import simd

/// Bounded geometry: two reusable gloves, no per-frame meshes or animations.
final class VirtualHands {
    private static let category = 1 << 9
    private final class Glove {
        let root = SCNNode(), palm = SCNNode(), cuff = SCNNode(), thumbPad = SCNNode()
        var fingers: [SCNNode] = []
        var timestamp = -Double.infinity
        init(material: SCNMaterial, accent: SCNMaterial) {
            let body = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.22)
            body.chamferSegmentCount = 3; body.firstMaterial = material
            palm.geometry = body
            let pad = SCNSphere(radius: 0.5); pad.segmentCount = 12; pad.firstMaterial = material
            thumbPad.geometry = pad
            let band = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.18)
            band.chamferSegmentCount = 3; band.firstMaterial = accent; cuff.geometry = band
            for node in [palm, cuff, thumbPad] { root.addChildNode(node); node.categoryBitMask = VirtualHands.category }
            for _ in 0..<15 {
                let bone = SCNCapsule(capRadius: 0.5, height: 2)
                bone.radialSegmentCount = 10; bone.capSegmentCount = 3
                bone.firstMaterial = material
                let node = SCNNode(geometry: bone); node.categoryBitMask = VirtualHands.category
                root.addChildNode(node); fingers.append(node)
            }
            root.isHidden = true
        }
        func hide() { root.isHidden = true; timestamp = -.infinity }
        func show(_ pose: VirtualHandPose, timestamp: Double) {
            self.timestamp = timestamp; root.isHidden = false
            let basis = simd_float3x3(columns: (pose.across, pose.along, pose.normal))
            let rotation = simd_quatf(basis)
            let thickness = max(0.012, min(0.025, pose.width*0.32))
            palm.simdPosition = pose.center
            palm.simdOrientation = rotation
            palm.simdScale = SIMD3(pose.width*1.22, pose.length*1.05, thickness)
            cuff.simdPosition = pose.center-pose.along*pose.length*0.53
            cuff.simdOrientation = rotation
            cuff.simdScale = SIMD3(pose.width*0.65, pose.length*0.17, thickness*0.9)
            if let thumb = pose.points[1], VirtualHandPose.length(thumb-pose.center) < pose.length {
                thumbPad.isHidden = false; thumbPad.simdPosition = (thumb+pose.center)*0.5
                thumbPad.simdOrientation = rotation
                thumbPad.simdScale = SIMD3(pose.width*0.62, pose.length*0.75, thickness*1.12)
            } else { thumbPad.isHidden = true }
            let factors: [Float] = [1.12, 1, 1, 0.93, 0.8]
            let taper: [Float] = [1, 0.84, 0.65]
            for finger in 0..<5 {
                for joint in 0..<3 {
                    let node = fingers[finger*3+joint]
                    guard let (a, b) = pose.segment(finger: finger, joint: joint) else { node.isHidden = true; continue }
                    let delta = b-a, length = simd_length(delta)
                    let radius = pose.width*0.13*factors[finger]*taper[joint]
                    node.isHidden = false; node.simdPosition = (a+b)*0.5
                    node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: delta/length)
                    node.simdScale = SIMD3(radius*2, (length+radius*2)*0.5, radius*2)
                }
            }
            // Shrink the glove around its palm center without moving the
            // pointer or changing the gesture/tracking coordinates.
            for node in [palm, cuff, thumbPad] + fingers where !node.isHidden {
                node.simdPosition = pose.center + (node.simdPosition-pose.center)*0.78
                node.simdScale *= 0.78
            }
        }
    }
    private let root = SCNNode(), key = SCNNode()
    private let left: Glove, right: Glove
    init() {
        let pearl = SCNMaterial(); pearl.lightingModel = .lambert
        pearl.diffuse.contents = UIColor(white: 0.88, alpha: 1)
        pearl.emission.contents = UIColor(white: 0.07, alpha: 1)
        let accent = SCNMaterial(); accent.lightingModel = .lambert
        accent.diffuse.contents = UIColor(red: 0.28, green: 0.70, blue: 0.82, alpha: 1)
        left = Glove(material: pearl, accent: accent); right = Glove(material: pearl, accent: accent)
        root.addChildNode(left.root); root.addChildNode(right.root)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 550; ambient.light?.categoryBitMask = Self.category
        key.light = SCNLight(); key.light?.type = .directional
        key.light?.intensity = 650; key.light?.categoryBitMask = Self.category
        key.light?.castsShadow = false
        root.addChildNode(ambient); root.addChildNode(key)
    }
    func start(in scene: SCNScene) { stop(); scene.rootNode.addChildNode(root) }
    func stop() { left.hide(); right.hide(); root.removeFromParentNode() }
    func update(hand: TrackedHand, pose: VirtualHandPose?, timestamp: Double, at time: Double, visible: Bool) {
        let glove = hand == .left ? left : right
        guard visible, VirtualHandPose.fresh(timestamp, at: time), let pose else { glove.hide(); return }
        glove.show(pose, timestamp: timestamp)
    }
    func tick(at time: Double, ready: Bool, head: SCNNode) {
        key.simdWorldOrientation = head.simdWorldOrientation
        for glove in [left, right] where !ready || !VirtualHandPose.fresh(glove.timestamp, at: time) { glove.hide() }
    }
}
#endif
