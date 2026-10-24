import Foundation

@main struct FeetTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition,label); count += 1 }
        let forward = SIMD3<Float>(0,0,-1), floor = GraffitiRoomLayout.floorY
        var motion = GraffitiLegMotion()
        let initial = motion.update(head:.zero,forward:forward,time:0,ready:true)
        check(initial.count == 2 && !motion.continuous,"first pose cannot kick")
        check(initial[0].center.x < 0 && initial[1].center.x > 0,"separate left and right legs")
        for i in 1...120 {
            let feet = motion.update(head:.zero,forward:forward,time:Double(i)/60,ready:true)
            check(motion.continuous && feet.map(\.center) == initial.map(\.center),"stationary head keeps feet still")
        }
        var sawLeftStep = false, sawRightStep = false
        for i in 1...240 {
            let feet = motion.update(head:SIMD3(0,0,-Float(i)*0.01),forward:forward,time:2+Double(i)/60,ready:true)
            check(feet.allSatisfy { $0.center.y >= floor+0.074 && $0.center.y < floor+0.14 },"feet lift without sinking through floor")
            check(feet.allSatisfy { GraffitiFlight.length($0.velocity) <= 3.001 },"bounded foot velocity")
            sawLeftStep = sawLeftStep || feet[0].center.y > floor+0.11
            sawRightStep = sawRightStep || feet[1].center.y > floor+0.11
        }
        check(sawLeftStep && sawRightStep,"both legs take turns stepping")
        let down = motion.update(head:SIMD3(0,0,-2.4),forward:SIMD3(0,-1,0),time:6.02,ready:true)
        check(down[0].forward == forward,"looking down preserves heading")
        _ = motion.update(head:SIMD3(3,0,-2.4),forward:forward,time:6.04,ready:true)
        check(!motion.continuous,"teleport cannot kick")
        check(motion.update(head:.zero,forward:forward,time:6.06,ready:false).isEmpty,"tracking loss hides legs")
        _ = motion.update(head:.zero,forward:forward,time:6.08,ready:true)
        check(!motion.continuous,"reacquired head cannot kick")
        _ = motion.update(head:.zero,forward:forward,time:7,ready:true)
        check(!motion.continuous,"resume after pause cannot kick")
        check(motion.update(head:SIMD3(.nan,0,0),forward:forward,time:7.02,ready:true).isEmpty,"non-finite pose rejected")
        let turned = motion.update(head:.zero,forward:SIMD3(1,0,0),time:7.04,ready:true)
        check(turned[0].center.z < 0 && turned[1].center.z > 0,"body heading rotates foot spacing")
        func feet(_ z: Float, old: Float? = nil, speed: Float = 0) -> [GraffitiFootPose] {
            [GraffitiFootPose(center:SIMD3(0,floor+0.075,z),forward:forward,
                previous:SIMD3(0,floor+0.075,old ?? z),velocity:SIMD3(0,0,-speed)),
             GraffitiFootPose(center:SIMD3(3,floor+0.075,0),forward:forward,
                previous:SIMD3(3,floor+0.075,0),velocity:.zero)]
        }
        var contact = GraffitiFootContact()
        let ball = SIMD3<Float>(0,floor+0.139,-0.4)
        func hit(_ positions: [GraffitiFootPose], enabled: Bool = true, at point: SIMD3<Float>? = nil,
                 velocity: SIMD3<Float> = .zero) -> (position:SIMD3<Float>,velocity:SIMD3<Float>)? {
            contact.hit(feet:positions,ball:point ?? ball,velocity:velocity,radius:0.111,enabled:enabled)
        }
        check(hit(feet(-0.24)) == nil,"spawning overlapping the ball never kicks")
        check(hit(feet(0)) == nil,"separation arms without kicking")
        let gentle = hit(feet(-0.24,old:0))!
        check(gentle.velocity.z < -1 && gentle.velocity.y > 0,"contact produces forward bounce")
        check(gentle.position.z < ball.z,"contact separates the ball from the shoe")
        for _ in 0..<30 { check(hit(feet(-0.24)) == nil,"overlap does not repeat kick") }
        _ = hit(feet(0))
        let strong = hit(feet(-0.24,old:0,speed:2))!
        check(-strong.velocity.z > -gentle.velocity.z,"faster approach produces stronger kick")
        check(GraffitiFlight.length(strong.velocity) <= 5,"kick speed bounded")
        check(hit(feet(-0.24),enabled:false) == nil,"held ball or inactive room disables contact")
        check(hit(feet(-0.24)) == nil,"release while overlapping requires separation")
        _ = hit(feet(0))
        check(hit(feet(-0.24),at:ball+SIMD3(0,1,0)) == nil,"ball above the feet does not collide")
        contact.reset(); _ = hit(feet(0))
        check(hit(feet(-0.7,old:0,speed:3)) != nil,"swept contact catches a ball crossed between frames")
        contact.reset(); _ = hit(feet(0))
        check(hit(feet(0),at:SIMD3(0,floor+0.139,-0.15),velocity:SIMD3(0,0,1))!.velocity.z < 0,
              "rolling ball rebounds from a stationary foot")
        contact.reset(); _ = hit(feet(0))
        let touching = feet(-0.24)[0]
        check(hit([touching,touching]) != nil,"simultaneous shoe contact produces a kick")
        check(hit([touching,touching]) == nil,"second shoe cannot immediately repeat the same contact")
        var flight = GraffitiFlight(position:strong.position,velocity:strong.velocity,angles:.zero,
            spin:SIMD3(strong.velocity.z*4,0,-strong.velocity.x*4))
        for _ in 0..<240 { _ = flight.step(1/60,halfSize:SIMD3(repeating:0.111),obstacles:[],ball:true) }
        check(flight.angles != .zero && flight.position.z < ball.z,"kicked ball travels and spins in actual physics")
        check(flight.position.y >= floor+0.138,"kicked ball stays above floor")
        print("PASS: \(count) virtual legs and foot/ball contact checks")
    }
}
