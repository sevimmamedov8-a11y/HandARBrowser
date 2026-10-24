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
        let sound: GraffitiSound
        let marker: SCNNode
        var flight: GraffitiFlight?
        var lastImpact = -Double.infinity
        var radius: Float { simd_length(halfSize) }
    }
    private struct Slot {
        var gate = GraffitiGrabGate()
        var generation: UInt64?
        var target: Int?
        var lastSeen = -Double.infinity
        var reach: Float = 0.6
        var previousPosition: SIMD3<Float>?
        var velocity = SIMD3<Float>.zero
    }
    private var items: [Item] = []
    private var left = Slot(), right = Slot()
    private var lastTick: Double?
    private var materials: [UIColor: SCNMaterial] = [:]
    private lazy var highlightMaterial: SCNMaterial = {
        let material = SCNMaterial(); material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemCyan.withAlphaComponent(0.17)
        material.writesToDepthBuffer = false
        return material
    }()
    var onPickColor: ((Int) -> Void)?
    var onInteraction: ((GraffitiSound) -> Void)?
    var onHint: ((String) -> Void)?

    @discardableResult
    func add(parts: [SCNNode], name: String, center: SCNVector3, halfSize: SIMD3<Float>, color: Int? = nil, sound: GraffitiSound = .wood, in room: SCNNode) -> SCNNode {
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
        items.append(Item(node: node, name: name, home: SIMD3(center.x, center.y, center.z), halfSize: halfSize, color: color, sound: sound, marker: marker))
        return node
    }

    func blocksPainting(_ hand: TrackedHand?) -> Bool {
        guard let hand else { return false }
        let slot = hand == .left ? left : right
        return slot.gate.held != nil || slot.target != nil || slot.gate.suppressPainting
    }
    var holdingAnything: Bool { left.gate.held != nil || right.gate.held != nil }
    func isHeld(_ node: SCNNode?) -> Bool {
        guard let node, let id = items.firstIndex(where: { $0.node === node }) else { return false }
        return left.gate.held == id || right.gate.held == id
    }

    private func settle(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        item.node.eulerAngles = SCNVector3Zero
        item.node.simdPosition = GraffitiPropGeometry.restingPosition(item.node.simdPosition, halfSize: item.halfSize)
        items[index].flight = nil
    }

    private func cancel(_ slot: inout Slot) {
        if let held = slot.gate.held { settle(held) }
        _ = slot.gate.cancel(); slot.target = nil; slot.previousPosition = nil; slot.velocity = .zero
    }

    func cancel() {
        // Work on copies to avoid overlapping access to self during settlement.
        var l = left, r = right; cancel(&l); cancel(&r); left = l; right = r
        refreshHighlights()
    }
    func reset() {
        cancel(); left = Slot(); right = Slot()
        for item in items { item.node.simdPosition = item.home; item.node.eulerAngles = SCNVector3Zero }
        for index in items.indices { items[index].flight = nil }
    }
    func clear() {
        cancel()
        for item in items { item.node.removeFromParentNode() }
        items.removeAll(); materials.removeAll(); left = Slot(); right = Slot(); lastTick = nil
    }

    func update(hand: TrackedHand, generation: UInt64?, fist: Bool, open: Bool,
                ray: WorldRay?, distance: Float, orientation: simd_quatf,
                blocked: Bool, ready: Bool, at time: Double) {
        var slot = hand == .left ? left : right
        let other = hand == .left ? right : left
        if slot.generation != generation { cancel(&slot); slot.generation = generation }
        let reliable = ready && ray != nil && generation != nil
        let elapsed = time-slot.lastSeen
        if let held = slot.gate.held, let ray, reliable {
            move(held, slot: &slot, ray: ray, orientation: orientation, elapsed: elapsed)
        }
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
            items[id].flight = nil
            slot.reach = max(0.45, distance) + items[id].radius*0.65
            slot.previousPosition = nil; slot.velocity = .zero
            if let ray { move(id, slot: &slot, ray: ray, orientation: orientation, elapsed: 0) }
            if let color = items[id].color { onPickColor?(color) }
            onHint?("\(items[id].name) · держи ладонь открытой 2 с для отпускания")
            onInteraction?(.grab)
        case .released(let id):
            let velocity = GraffitiFlight.capped(slot.velocity, at: 5)
            let e = items[id].node.eulerAngles
            items[id].flight = GraffitiFlight(position: items[id].node.simdPosition, velocity: velocity,
                angles: SIMD3(e.x,e.y,e.z), spin: GraffitiFlight.capped(SIMD3(velocity.z,velocity.x*0.3,-velocity.x)*1.8, at: 8))
            slot.previousPosition = nil; slot.velocity = .zero
            onHint?("Отпущено · закрой руку в стороне от вещей перед рисованием")
        case .cancelled(let id): settle(id)
        case .none: break
        }
        if let id = slot.gate.held, slot.gate.releaseProgress > 0 {
            onHint?("\(items[id].name) · отпускание \(Int(slot.gate.releaseProgress*100))%")
        }
        if let target, !fist { onHint?("\(items[target].name) · сожми кулак, чтобы взять") }
        if hand == .left { left = slot } else { right = slot }
        refreshHighlights()
    }

    private func move(_ id: Int, slot: inout Slot, ray: WorldRay, orientation: simd_quatf, elapsed: Double) {
        items[id].node.simdWorldPosition = ray.point(at: slot.reach)
        items[id].node.simdWorldOrientation = orientation
        let position = items[id].node.simdPosition
        if let previous = slot.previousPosition, elapsed > 0.005, elapsed <= 0.2,
           simd_length(position-previous) < 0.45 {
            let measured = GraffitiFlight.capped((position-previous)/Float(elapsed), at: 5)
            slot.velocity = slot.velocity*0.4 + measured*0.6
        } else { slot.velocity = .zero }
        slot.previousPosition = position
    }

    func tick(at time: Double, ready: Bool) {
        var l = left, r = right
        if !ready || !time.isFinite || time-l.lastSeen > 0.2 || time < l.lastSeen { cancel(&l) }
        if !ready || !time.isFinite || time-r.lastSeen > 0.2 || time < r.lastSeen { cancel(&r) }
        left = l; right = r; refreshHighlights()
        let elapsed = Float(min(0.05, max(0, time-(lastTick ?? time))))
        lastTick = time
        guard ready else { return }
        let bench = GraffitiCollider(center: SIMD3(-1.65, GraffitiRoomLayout.floorY+0.88, GraffitiRoomLayout.benchZ), half: SIMD3(1.25,0.05,0.325))
        let lounge = GraffitiCollider(center: SIMD3(4.7, GraffitiRoomLayout.floorY+0.3, 3.45), half: SIMD3(0.75,0.3,1.25))
        for index in items.indices {
            guard var flight = items[index].flight, !flight.resting else { continue }
            var obstacles = [bench,lounge]
            for other in items.indices where other != index && left.gate.held != other && right.gate.held != other {
                let node = items[other].node, e = node.eulerAngles
                let half = GraffitiFlight.extent(half: items[other].halfSize, angles: SIMD3(e.x,e.y,e.z))
                obstacles.append(GraffitiCollider(center: node.simdPosition, half: half))
            }
            let impact = flight.step(elapsed, halfSize: items[index].halfSize, obstacles: obstacles)
            items[index].node.simdPosition = flight.position
            items[index].node.eulerAngles = SCNVector3(flight.angles.x,flight.angles.y,flight.angles.z)
            items[index].flight = flight
            if impact > 0.6 && time-items[index].lastImpact > 0.12 {
                items[index].lastImpact = time; onInteraction?(items[index].sound)
            }
        }
    }
    private func refreshHighlights() {
        for (index, item) in items.enumerated() {
            let targeted = left.target == index || right.target == index
            let held = left.gate.held == index || right.gate.held == index
            item.marker.isHidden = !targeted || held
        }
    }
}
