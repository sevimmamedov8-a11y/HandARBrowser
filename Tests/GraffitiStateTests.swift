import Foundation

@main struct GraffitiStateTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1 }
        var gate = GraffitiSprayGate()
        func sample(_ time: Double, open: Bool = true, hand: TrackedHand? = .right,
                    reliable: Bool = true, blocked: Bool = false) -> Bool {
            gate.update(hand: hand, open: open, reliable: reliable, blocked: blocked, at: time)
        }
        check(!gate.isEnabled && !gate.canVisible, "painting starts switched off")
        check(!gate.toggle(at: 0), "head dwell without an observed palm cannot arm painting")
        check(!sample(0) && !gate.canVisible, "open palm alone never paints")
        check(gate.toggle(at: 0.01), "explicit toggle with a fresh open palm enables painting")
        check(!sample(0.04, blocked: true) && gate.isEnabled, "the enable button pauses paint without immediately turning it off")
        check(!gate.canVisible, "can does not cover the control being used")
        check(sample(0.08) && gate.canVisible, "leaving the button paints and shows the can")
        for i in 3...20 { check(sample(Double(i) * 0.04), "held open palm continues spray") }
        check(!sample(0.84, open: false) && !gate.canVisible, "non-open pose immediately pauses and hides the can")
        check(gate.isEnabled, "brief uncertain finger pose does not require repeated toggles")
        check(sample(0.88), "open palm resumes after a pose-only pause")
        check(gate.toggle(at: 0.90) && !gate.isEnabled && !gate.canVisible, "second toggle stops immediately")
        check(!sample(0.92) && !sample(0.96), "continued open palm cannot undo explicit stop")
        check(gate.toggle(at: 0.98) && sample(1), "explicit restart")
        check(!sample(1.04, hand: nil) && !gate.canVisible && !gate.isEnabled, "missing hand disables paint")
        check(!sample(1.08) && !sample(1.12), "reacquired open palm cannot resume without toggle")
        check(gate.toggle(at: 1.14) && sample(1.16), "explicit toggle after reacquisition paints")
        check(!sample(1.20, hand: .left) && !gate.isEnabled, "left hand cannot inherit right spray state")
        check(gate.owner == .left, "ownership switches explicitly")
        check(!sample(1.24, hand: .left), "new hand stays disabled")
        check(gate.toggle(at: 1.26) && sample(1.28, hand: .left), "new hand paints after its own toggle")
        check(!sample(1.32, hand: .left, blocked: true) && gate.isEnabled, "hover pauses paint while a stop dwell is in progress")
        gate.cancel() // Opening the palette disables painting, rather than merely hovering it.
        check(!sample(1.36, hand: .left, blocked: true) && !gate.canVisible, "palette remains free of paint")
        check(!sample(1.40, hand: .left) && !gate.isEnabled, "closing the palette cannot resume paint")
        check(gate.toggle(at: 1.42) && sample(1.44, hand: .left), "explicit restart after palette")
        check(!sample(2, hand: .left) && !gate.isEnabled, "sample gap disables spray")
        check(gate.toggle(at: 2.01), "restart after a fresh sample following gap")
        check(!sample(2.04, hand: .left, reliable: false) && !gate.canVisible, "limited AR tracking stops and hides can")
        check(!gate.isEnabled && !gate.toggle(at: 2.05), "tracking recovery needs a fresh palm and explicit enable")
        check(!sample(2.08, hand: .left) && gate.toggle(at: 2.09), "fresh tracking can be enabled explicitly")
        check(!sample(2.07, hand: .left) && !gate.isEnabled, "backwards sample time cancels paint")
        check(!sample(.nan), "invalid timestamp never sprays")
        check(!gate.toggle(at: .nan), "invalid toggle timestamp rejected")
        _ = sample(3, open: false)
        check(!gate.toggle(at: 3.01), "a fist cannot arm painting")
        _ = sample(3.04)
        check(!gate.toggle(at: 3.5), "stale palm cannot arm head dwell")
        check(!gate.toggle(at: 3.03), "future palm timestamp cannot arm painting")
        _ = sample(3.52)
        check(gate.toggle(at: 3.53) && sample(3.56), "fresh open palm can restart after rejection")
        gate.cancel(); check(!gate.canVisible && !gate.isEnabled, "app exit clears visible state")

        var sampler = GraffitiStrokeSampler()
        check(sampler.points(to: .zero, radius: 0.045, at: 0).count == 1, "first stamp")
        check(sampler.points(to: SIMD2(0.1, 0), radius: 0.045, at: 0.01).isEmpty, "spray has a bounded cadence")
        let connected = sampler.points(to: SIMD2(0.3, 0), radius: 0.045, at: 0.05)
        check(connected.count > 1 && connected.count <= 48, "movement fills the gap with a bounded number of stamps")
        check(connected.last == SIMD2(0.3, 0), "stroke reaches the hand position")
        for pair in zip(connected, connected.dropFirst()) {
            check(pair.1.x - pair.0.x <= 0.045 * 0.35 + 0.0001, "no holes along a normal stroke")
        }
        check(sampler.points(to: SIMD2(1.3, 0), radius: 0.045, at: 0.1).count == 1, "tracking jump does not draw across room")
        check(sampler.points(to: SIMD2(1.5, 0), radius: 0.045, at: 1).count == 1, "late hand does not bridge missing frames")
        sampler.reset()
        check(sampler.points(to: SIMD2(1.55, 0), radius: 0.045, at: 1.05).count == 1, "new wall/stroke never connects to previous one")
        check(sampler.points(to: SIMD2(.nan, 0), radius: 0.045, at: 2).isEmpty, "invalid geometry rejected")
        check(sampler.points(to: .zero, radius: 0, at: 3).isEmpty, "invalid radius rejected")
        check(GraffitiGeometry.uv(point: .zero, size: SIMD2(2, 2)) == SIMD2(0.5, 0.5), "wall center")
        check(GraffitiGeometry.uv(point: SIMD2(-1, 1), size: SIMD2(2, 2)) == SIMD2(0, 0), "top left")
        check(GraffitiGeometry.uv(point: SIMD2(1, -1), size: SIMD2(2, 2)) == SIMD2(1, 1), "bottom right")
        check(GraffitiGeometry.uv(point: SIMD2(1.01, 0), size: SIMD2(2, 2)) == nil, "wall boundary rejects outside marks")
        for fraction in stride(from: 0.01, through: 1.0, by: 0.01) {
            let distance = GraffitiGeometry.canDistance(palmFraction: fraction, verticalTangent: 0.7)
            check(distance >= 0.25 && distance <= 0.85, "can depth remains in useful range")
        }
        check(GraffitiGeometry.canDistance(palmFraction: .nan, verticalTangent: 1) == 0.5, "invalid depth has stable fallback")
        let span = GraffitiRoomLayout.span, height = GraffitiRoomLayout.wallHeight
        check(span >= 8 && height >= 4, "room is larger in width and height")
        check(abs(GraffitiRoomLayout.wallCenterY - height * 0.5 - GraffitiRoomLayout.floorY) < 0.0001,
              "expanded walls meet the floor")
        check(abs(GraffitiRoomLayout.wallCenterY + height * 0.5 - GraffitiRoomLayout.ceilingY) < 0.0001,
              "expanded walls meet the ceiling")
        check(sqrt(2 * span * span + height * height) < GraffitiRoomLayout.maximumPaintDistance,
              "spray ray can reach the farthest point of the expanded room")
        print("PASS: \(count) graffiti palm, toggle, loss, hand ownership, palette, stroke and wall-coordinate checks")
    }
}
