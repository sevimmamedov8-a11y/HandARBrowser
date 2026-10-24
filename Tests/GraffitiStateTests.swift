import Foundation

@main struct GraffitiStateTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1 }
        var gate = GraffitiSprayGate()
        func sample(_ time: Double, _ fist: Bool, hand: TrackedHand? = .right,
                    open: Bool = false, reliable: Bool = true, blocked: Bool = false) -> Bool {
            gate.update(hand: hand, fist: fist, open: open, reliable: reliable, blocked: blocked, at: time)
        }
        check(sample(0, true), "first confirmed fist can spray")
        check(gate.canVisible, "fist shows can")
        for i in 1...20 { check(sample(Double(i) * 0.04, true), "held fist continues spray") }
        check(!sample(0.84, false, open: true) && !gate.canVisible, "opening immediately stops and hides can")
        check(sample(0.88, true), "normal next fist paints without tracking interruption")
        check(!sample(0.92, false, hand: nil) && !gate.canVisible, "missing hand stops spray and hides can")
        check(!sample(0.96, true) && gate.canVisible, "reacquired closed fist is visible but cannot create an accidental mark")
        check(!sample(1, false, open: true), "open palm begins rearm")
        check(!sample(1.04, true), "short opening does not rearm after loss")
        _ = sample(1.08, false, open: true); _ = sample(1.20, false, open: true)
        check(sample(1.24, true), "confirmed opening rearms")
        check(!sample(1.28, true, hand: .left), "left hand cannot inherit right spray state")
        check(gate.owner == .left, "ownership switches explicitly")
        _ = sample(1.32, false, hand: .left, open: true); _ = sample(1.44, false, hand: .left, open: true)
        check(sample(1.48, true, hand: .left), "new hand paints after opening")
        check(!sample(1.52, true, hand: .left, blocked: true), "palette consumes fists")
        check(!sample(1.56, true, hand: .left), "closing palette cannot resume a held fist")
        _ = sample(1.60, false, hand: .left, open: true); _ = sample(1.72, false, hand: .left, open: true)
        check(sample(1.76, true, hand: .left), "palette handoff rearms by opening")
        check(!sample(2.2, true, hand: .left), "sample gap cancels spray")
        check(!sample(2.24, true, hand: .left, reliable: false) && !gate.canVisible, "limited AR tracking hides can and stops paint")
        check(!sample(.nan, true), "invalid timestamp never sprays")
        gate.cancel(); check(!gate.canVisible && !gate.armed, "app exit clears visible state")

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
        print("PASS: \(count) graffiti fist, loss, hand ownership, palette, stroke and wall-coordinate checks")
    }
}
