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
        check(frame(0, fist: true) == .none, "one frame is not a grab")
        check(frame(0.04) == .none, "fist flicker is cancelled")
        for t in [0.08,0.12,0.16] { _ = frame(t,fist:true) }
        check(frame(0.20,fist:true) == .began(1), "stable fist grabs without opening first")
        for i in 6...100 {
            check(frame(Double(i)*0.04,target:2,blocked:i%2==0) == .none && gate.held == 1,
                  "neutral fingers and UI crossings never drop or switch a held object")
        }
        check(gate.suppressPainting,"holding blocks paint")
        for i in 101...149 { _ = frame(Double(i)*0.04,open:true) }
        check(gate.held == 1 && gate.releaseProgress > 0.9,"1.92 seconds is too short")
        _ = frame(6.0,fist:true)
        check(gate.releaseProgress == 0 && gate.held == 1,"closing resets the release countdown")
        for i in 151...200 { _ = frame(Double(i)*0.04,open:true) }
        check(gate.held == 1,"1.96 seconds still held")
        check(frame(8.04,open:true) == .released(1),"continuous two second palm releases once")
        for i in 202...210 { check(frame(Double(i)*0.04,open:true) == .none && gate.suppressPainting,"release cannot paint") }
        for i in 211...214 { _ = frame(Double(i)*0.04,target:nil,fist:true) }
        check(!gate.suppressPainting,"closing away from props restores later painting")
        for i in 215...218 { _ = frame(Double(i)*0.04,fist:true) }
        check(gate.held == 1,"fist can grab again")
        check(frame(8.80,reliable:false) == .cancelled(1),"hand loss cancels instead of throwing")
        for i in 221...224 { _ = frame(Double(i)*0.04,fist:true) }
        check(gate.held == 1,"fresh fist can confirm again")
        check(frame(10,fist:true) == .cancelled(1),"frame gap cancels")
        check(frame(.nan,fist:true) == .none && gate.held == nil,"invalid clock cannot grab")
        for i in 0..<20 { _ = frame(11+Double(i)*0.04,target:i%2,fist:true) }
        check(gate.held == nil,"flickering between props never confirms")
        for i in 0..<10 { _ = frame(12+Double(i)*0.04,fist:true,blocked:true) }
        check(gate.held == nil,"UI prevents a new grab")
        // Actual ballistic integrator: travel, containment, rest and tabletop.
        let small = SIMD3<Float>(repeating:0.1)
        var flight = GraffitiFlight(position:.zero,velocity:SIMD3(3,2,-1),angles:.zero,spin:SIMD3(0,0,4))
        var impacts = 0, previous = flight.position
        for _ in 0..<600 {
            if flight.step(1.0/60,halfSize:small,obstacles:[]) > 0.6 { impacts += 1 }
            let extent = GraffitiFlight.extent(half:small,angles:flight.angles)
            check(flight.position.y-extent.y >= GraffitiRoomLayout.floorY+0.027,"flight stays above floor")
            check(abs(flight.position.x)+extent.x <= 6.001 && abs(flight.position.z)+extent.z <= 6.001,"throws stay inside room")
            previous = flight.position
        }
        check(flight.resting && impacts > 0 && flight.position.x > 0.5,"throw travels, bounces and rests")
        var tableFlight = GraffitiFlight(position:SIMD3(0,1,0),velocity:SIMD3(0,-5,0),angles:.zero,spin:.zero)
        let tabletop = GraffitiCollider(center:SIMD3(0,-0.5,0),half:SIMD3(1,0.05,1))
        for _ in 0..<300 { _ = tableFlight.step(1.0/60,halfSize:small,obstacles:[tabletop]) }
        check(tableFlight.resting && abs(tableFlight.position.y+0.35)<0.002,"falls onto thin tabletop without tunnelling")
        for half in [SIMD3<Float>(0.058,0.14,0.06), SIMD3(0.18,0.41,0.07), SIMD3(0.31,0.34,0.15)] {
            var drop = GraffitiFlight(position:SIMD3(2,1,0),velocity:.zero,angles:.zero,
                spin:GraffitiFlight.releaseSpin(velocity:.zero,hand:.left))
            for _ in 0..<12 { _ = drop.step(1.0/60,halfSize:half,obstacles:[]) }
            check(GraffitiFlight.length(drop.angles)>0.1,"stationary hand still releases a tumbling body")
            for _ in 0..<1200 { _ = drop.step(1.0/60,halfSize:half,obstacles:[]) }
            check(drop.resting,"can, skateboard and radio settle after tumbling")
            let extent = GraffitiFlight.extent(half:half,angles:drop.angles)
            check(extent.y <= min(half.x,min(half.y,half.z))+0.003,"prop rests on a low face instead of standing on an edge")
        }
        var ball = GraffitiFlight(position:SIMD3(0,1,0),velocity:SIMD3(1.5,0,0),angles:.zero,spin:.zero)
        var bounced = false, rebound: Float = -100, travelled: Float = 0
        for _ in 0..<1200 {
            let hit = ball.step(1.0/60,halfSize:SIMD3(repeating:0.111),obstacles:[],ball:true)
            if hit > 1 { bounced = true }
            if bounced { rebound = max(rebound,ball.position.y); travelled = max(travelled,abs(ball.position.x)) }
            check(ball.position.y >= GraffitiRoomLayout.floorY+0.138,"sphere retains fixed collision radius while rotating")
        }
        check(bounced && rebound > -0.5,"football has a visible elastic rebound")
        check(ball.resting && travelled > 1.5 && GraffitiFlight.length(ball.angles)>1,"football rolls, rotates and eventually stops")
        let mesh = GraffitiFootball.patches()
        check(mesh.vertices.count == 552 && mesh.indices.count == 2700,"twelve curved pentagons stay within mesh budget")
        for v in mesh.vertices { check(abs(GraffitiFlight.length(v)-1.006)<0.0001,"football patches follow spherical surface") }
        check(mesh.indices.allSatisfy { $0>=0 && Int($0)<mesh.vertices.count },"football triangles only reference valid vertices")
        let savedPosition = tableFlight.position
        _ = tableFlight.step(.nan,halfSize:small,obstacles:[])
        check(savedPosition == tableFlight.position,"invalid time has no motion")
        _ = previous
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
