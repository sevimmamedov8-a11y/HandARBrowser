import Foundation

@main struct GrabTests {
    static func main() {
        var count = 0
        func check(_ result: Bool, _ label: String) { precondition(result, label); count += 1 }
        var gate = GraffitiGrabGate()
        func frame(_ t: Double, target: Int? = 1, fist: Bool = false, open: Bool = false,
                   reliable: Bool = true, blocked: Bool = false) -> GraffitiGrabGate.Event {
            gate.update(target: target, fist: fist, open: open, reliable: reliable, blocked: blocked, at: t)
        }
        for i in 0..<8 { check(frame(Double(i)*0.04, fist: true) == .none, "appearing as a fist cannot take an object") }
        check(gate.held == nil, "must first observe an open palm")
        _ = frame(0.32, open: true);_ = frame(0.36, open: true);_ = frame(0.40, open: true)
        _ = frame(0.44, fist: true)
        check(frame(0.48, fist: false) == .none, "one flickering fist does not grab")
        _ = frame(0.52, fist: true);_ = frame(0.56, fist: true);_ = frame(0.60, fist: true)
        check(frame(0.64, fist: true) == .began(1), "stable aimed fist takes once")
        for i in 17...24 { check(frame(Double(i)*0.04, target: 2, fist: true) == .none && gate.held == 1, "hold cannot jump to another target") }
        check(gate.suppressPainting, "holding blocks automatic palm paint")
        check(frame(1, open: true) == .none && gate.held == 1, "brief opening does not drop")
        _ = frame(1.04, open: true)
        check(frame(1.08, open: true) == .released(1) && gate.held == nil, "confirmed opening drops once")
        for i in 28...34 { check(frame(Double(i)*0.04, open: true) == .none && gate.suppressPainting, "drop opening cannot become a paint stroke") }
        _ = frame(1.40, target: nil, fist: true)
        check(gate.suppressPainting, "one uncertain frame after dropping cannot unlock paint")
        var reset = gate
        _ = reset.update(target: nil, fist: false, open: true, reliable: true, blocked: false, at: 1.44)
        check(reset.suppressPainting, "returning open palm remains a drop gesture")
        for i in 0...3 { _ = reset.update(target: nil, fist: true, open: false, reliable: true, blocked: false, at: 1.48+Double(i)*0.04) }
        check(!reset.suppressPainting, "stable closing away from props allows a later paint gesture")
        _ = frame(1.44, fist: true);_ = frame(1.48, fist: true);_ = frame(1.52, fist: true)
        check(frame(1.56, fist: true) == .began(1), "a new deliberate fist can grab after dropping")
        check(frame(1.60, fist: true, reliable: false) == .cancelled(1), "hand loss cancels carry")
        for i in 41...46 { check(frame(Double(i)*0.04, fist: true) == .none && gate.held == nil, "fist reacquisition cannot silently regrab") }
        _ = frame(1.88, open: true);_ = frame(1.92, open: true);_ = frame(1.96, open: true)
        _ = frame(2, fist: true);_ = frame(2.04, fist: true);_ = frame(2.08, fist: true)
        check(frame(2.12, fist: true) == .began(1), "open then fist recovers after loss")
        check(frame(2.16, fist: true, blocked: true) == .cancelled(1), "palette or mode switch ends carry")
        _ = frame(2.20, open: true);_ = frame(2.24, open: true);_ = frame(2.28, open: true)
        _ = frame(2.32, fist: true);_ = frame(2.36, target: 2, fist: true);_ = frame(2.40, fist: true)
        check(frame(2.44, target: 2, fist: true) == .none && gate.held == nil, "jitter between props resets confirmation")
        _ = frame(2.48, target: 2, fist: true);_ = frame(2.52, target: 2, fist: true)
        check(frame(2.56, target: 2, fist: true) == .began(2), "settled new target can be taken")
        check(frame(3, fist: true) == .cancelled(2), "delivery gap cannot bridge a grab")
        check(frame(.nan, fist: true) == .none && gate.held == nil, "invalid clock never creates a held object")
        gate = GraffitiGrabGate()
        _ = frame(4, open: true);_ = frame(4.04, open: true);_ = frame(4.08, open: true)
        _ = frame(4.12, fist: true);_ = frame(4.16, fist: true);_ = frame(4.20, fist: true);_ = frame(4.24, fist: true)
        check(gate.held == 1, "grab before uncertainty test")
        for i in 107...111 { _ = frame(Double(i)*0.04) }
        check(frame(4.48) == .cancelled(1), "sustained ambiguous pose releases stale carry")
        check(GraffitiPropGeometry.rayDistance(origin: .zero, direction: SIMD3(0,0,-1), center: SIMD3(0,0,-5), radius: 0.1) == 5, "remote fist can target across the room")
        check(GraffitiPropGeometry.rayDistance(origin: .zero, direction: SIMD3(0,0,-1), center: SIMD3(3,0,-5), radius: 0.1) == nil, "off-axis object cannot be taken")
        check(GraffitiPropGeometry.rayDistance(origin: .zero, direction: SIMD3(0,0,-1), center: SIMD3(0,0,1), radius: 0.1) == nil, "behind camera cannot be taken")
        let half = SIMD3<Float>(0.1,0.2,0.1)
        let table = GraffitiPropGeometry.restingPosition(SIMD3(-1.5,0,GraffitiRoomLayout.benchZ), halfSize: half)
        check(abs(table.y-(GraffitiRoomLayout.floorY+1.13)) < 0.0001, "drop above bench rests on its top")
        let under = GraffitiPropGeometry.restingPosition(SIMD3(-1.5,-1,GraffitiRoomLayout.benchZ), halfSize: half)
        check(under.y < table.y, "object below bench is not teleported onto it")
        for x: Float in [-100,0,100] { for z: Float in [-100,0,100] {
            let p = GraffitiPropGeometry.restingPosition(SIMD3(x,10,z), halfSize: half)
            check(abs(p.x)+half.x < 6 && abs(p.z)+half.z < 6, "dropped object stays within enlarged room")
            check(p.y >= GraffitiRoomLayout.floorY+half.y, "object never sinks below floor")
        } }
        var preferences = GraffitiPreferences()
        for density in 0...2 {
            preferences.density = density
            check(preferences.flow > 0 && 0.28*preferences.flow <= 1, "density remains valid paint opacity")
        }
        for brightness in 0...2 {
            preferences.brightness = brightness
            check(preferences.light > 0 && preferences.light <= 1, "lighting stays in valid material range")
        }
        let saved = UserDefaults.standard.data(forKey: "graffiti.preferences.v97")
        defer { UserDefaults.standard.set(saved, forKey: "graffiti.preferences.v97") }
        preferences.grid = false; preferences.hardEdge = true; preferences.animation = false
        preferences.save()
        check(GraffitiPreferences.load() == preferences, "settings persist across sessions")
        preferences.density = 999; preferences.save()
        check(GraffitiPreferences.load() == GraffitiPreferences(), "corrupt settings reset safely")
        print("PASS: \(count) fist confirmation, loss, release, paint isolation, placement and preferences checks")
    }
}
