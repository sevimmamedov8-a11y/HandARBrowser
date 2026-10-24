import SceneKit
import UIKit
import simd

/// Movable pieces stay separate from the flattened architecture. Two hands may
/// hold different objects, but the same object can only have one owner.
final class GraffitiProps {
    private struct Item {
        let node: SCNNode
        let name: String
        let home: SIMD3<Float>
        let halfSize: SIMD3<Float>
        let color: Int?
        let marker: SCNNode
        var radius: Float { simd_length(halfSize) }
    }
    private struct Slot {
        var gate = GraffitiGrabGate()
        var generation: UInt64?
        var target: Int?
        var lastSeen = -Double.infinity
    }
    private var items: [Item] = []
    private var left = Slot(), right = Slot()
    private var materials: [UIColor: SCNMaterial] = [:]
    private lazy var highlightMaterial: SCNMaterial = {
        let material = SCNMaterial(); material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemCyan.withAlphaComponent(0.17)
        material.writesToDepthBuffer = false
        return material
    }()
    var onPickColor: ((Int) -> Void)?
    var onInteraction: (() -> Void)?
    var onHint: ((String) -> Void)?

    func add(parts: [SCNNode], name: String, center: SCNVector3, halfSize: SIMD3<Float>, color: Int? = nil, in room: SCNNode) {
        let group = SCNNode()
        for part in parts {
            part.position = SCNVector3(part.position.x-center.x, part.position.y-center.y, part.position.z-center.z)
            if let surface = part.geometry?.firstMaterial, let color = surface.diffuse.contents as? UIColor {
                if let shared = materials[color] { part.geometry?.firstMaterial = shared }
                else { materials[color] = surface }
            }
            group.addChildNode(part)
        }
        let node = SCNNode(); node.name = name; node.addChildNode(group.flattenedClone())
        node.position = center; room.addChildNode(node)
        let outline = SCNBox(width: CGFloat(halfSize.x*2+0.035), height: CGFloat(halfSize.y*2+0.035),
                             length: CGFloat(halfSize.z*2+0.035), chamferRadius: 0.025)
        outline.firstMaterial = highlightMaterial
        let marker = SCNNode(geometry: outline); marker.isHidden = true; node.addChildNode(marker)
        items.append(Item(node: node, name: name, home: SIMD3(center.x, center.y, center.z), halfSize: halfSize, color: color, marker: marker))
    }

    func blocksPainting(_ hand: TrackedHand?) -> Bool {
        guard let hand else { return false }
        let slot = hand == .left ? left : right
        return slot.gate.held != nil || slot.target != nil || slot.gate.suppressPainting
    }
    var holdingAnything: Bool { left.gate.held != nil || right.gate.held != nil }

    private func settle(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        item.node.eulerAngles = SCNVector3Zero
        item.node.simdPosition = GraffitiPropGeometry.restingPosition(item.node.simdPosition, halfSize: item.halfSize)
    }

    private func cancel(_ slot: inout Slot) {
        if let held = slot.gate.held { settle(held) }
        _ = slot.gate.cancel(); slot.target = nil
    }

    func cancel() {
        // Work on copies to avoid overlapping access to self during settlement.
        var l = left, r = right; cancel(&l); cancel(&r); left = l; right = r
        refreshHighlights()
    }
    func reset() {
        cancel(); left = Slot(); right = Slot()
        for item in items { item.node.simdPosition = item.home; item.node.eulerAngles = SCNVector3Zero }
    }
    func clear() {
        cancel()
        for item in items { item.node.removeFromParentNode() }
        items.removeAll(); materials.removeAll(); left = Slot(); right = Slot()
    }

    func update(hand: TrackedHand, generation: UInt64?, fist: Bool, open: Bool,
                ray: WorldRay?, distance: Float, orientation: simd_quatf,
                blocked: Bool, ready: Bool, at time: Double) {
        var slot = hand == .left ? left : right
        let other = hand == .left ? right : left
        if slot.generation != generation { cancel(&slot); slot.generation = generation }
        let reliable = ready && ray != nil && generation != nil
        if reliable { slot.lastSeen = time }
        let target: Int? = (!blocked && reliable && slot.gate.held == nil) ? ray.flatMap { ray in
            var best: (Int, Float)?
            for (index, item) in items.enumerated() where other.gate.held != index {
                if let t = GraffitiPropGeometry.rayDistance(origin: ray.origin, direction: ray.direction,
                    center: item.node.simdWorldPosition, radius: item.radius) {
                    // Prefer the object under the pointer, not an adjacent can
                    // a few centimetres nearer inside the same assist cone.
                    let miss = simd_length(item.node.simdWorldPosition-ray.point(at: t))
                    let score = miss/max(0.04, min(0.25, item.radius)) + t*0.002
                    if best == nil || score < best!.1 { best = (index, score) }
                }
            }
            return best?.0
        } : nil
        slot.target = target
        let event = slot.gate.update(target: target, fist: fist, open: open, reliable: reliable, blocked: blocked, at: time)
        switch event {
        case .began(let id):
            if let color = items[id].color { onPickColor?(color) }
            onHint?("\(items[id].name) · раскрой ладонь — отпустить")
            onInteraction?()
        case .released(let id):
            settle(id); onInteraction?()
            onHint?("Отпущено · закрой руку в стороне от вещей перед рисованием")
        case .cancelled(let id): settle(id)
        case .none: break
        }
        if let id = slot.gate.held, let ray {
            let reach = max(0.45, distance) + items[id].radius*0.65
            items[id].node.simdWorldPosition = ray.point(at: reach)
            items[id].node.simdWorldOrientation = orientation
        }
        if let target, !fist { onHint?("\(items[target].name) · сожми кулак, чтобы взять") }
        if hand == .left { left = slot } else { right = slot }
        refreshHighlights()
    }

    func tick(at time: Double, ready: Bool) {
        var l = left, r = right
        if !ready || !time.isFinite || time-l.lastSeen > 0.2 || time < l.lastSeen { cancel(&l) }
        if !ready || !time.isFinite || time-r.lastSeen > 0.2 || time < r.lastSeen { cancel(&r) }
        left = l; right = r; refreshHighlights()
    }
    private func refreshHighlights() {
        for (index, item) in items.enumerated() {
            let targeted = left.target == index || right.target == index
            let held = left.gate.held == index || right.gate.held == index
            item.marker.isHidden = !targeted || held
        }
    }
}
