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
        check(!sample(0) && !gate.canVisible, "one open frame does not spray")
        check(!sample(0.04), "brief confirmation preserves fast response")
        check(sample(0.08) && gate.canVisible, "stable palm paints without a button")
        for i in 3...20 { check(sample(Double(i) * 0.04), "held palm keeps painting") }
        check(!sample(0.84, open: false) && !gate.canVisible, "closed palm immediately stops")
        check(!sample(0.88) && !sample(0.92), "new opening starts fresh confirmation")
        check(sample(0.96), "opening alone restarts")
        check(!sample(1, hand: nil) && !gate.canVisible, "lost hand stops immediately")
        check(!sample(1.04) && !sample(1.08) && sample(1.12), "returning palm starts a fresh stroke after confirmation")
        check(!sample(1.16, hand: .left), "another hand cannot inherit confirmation")
        check(gate.owner == .left, "new hand owns its own stroke")
        check(!sample(1.20, hand: .left) && sample(1.24, hand: .left), "new hand confirms independently")
        check(!sample(1.28, hand: .left, blocked: true) && !gate.canVisible, "controls immediately block spray")
        check(!sample(1.32, hand: .left, blocked: true), "held palm cannot spray through palette")
        check(!sample(1.36, hand: .left) && !sample(1.40, hand: .left) && sample(1.44, hand: .left),
              "leaving controls confirms again without a toggle")
        check(!sample(2, hand: .left), "frame gap ends old stroke")
        check(!sample(2.04, hand: .left, reliable: false), "unreliable tracking cancels")
        check(!sample(2.08, hand: .left) && !sample(2.12, hand: .left) && sample(2.16, hand: .left), "tracking recovery confirms again")
        check(!sample(2.15, hand: .left), "backwards time cancels")
        check(!sample(.nan), "invalid time cannot spray")
        gate.cancel();check(!gate.canVisible, "app exit hides the can")
        for i in 0..<20 { check(!sample(3 + Double(i) * 0.04, open: i % 2 == 0), "alternating uncertain pose never paints") }
        check(GraffitiRoomMood.neon.next == .sunset && GraffitiRoomMood.sunset.next == .mint && GraffitiRoomMood.mint.next == .neon,
              "three lighting moods cycle predictably")

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
        print("PASS: \(count) graffiti automatic palm, loss, hand ownership, palette, stroke and wall-coordinate checks")
    }
}
