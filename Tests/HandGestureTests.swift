@main
struct HandGestureTests {
    struct Trace {
        var gesture = StablePinchGesture()
        var time = 0.0
        var events: [PinchTransition] = []
        mutating func step(_ ratio: Double? = 0.6, confident: Bool = true, grabbing: Bool = false, dt: Double = 1.0/30) {
            time += dt
            let event = gesture.update(ratio:ratio,confident:confident,grabbing:grabbing,at:time)
            if event != .none { events.append(event) }
        }
        mutating func hold(_ ratio: Double?, frames: Int, dt: Double = 1.0/30) {
            for _ in 0..<frames { step(ratio,dt:dt) }
        }
        var presses: Int { events.filter{$0 == .pressed}.count }
        var releases: Int { events.filter{$0 == .released}.count }
    }
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(),message)
    }
    static func main() {
        for fps in [15.0,20,30,60] {
            let dt = 1/fps
            var t = Trace()
            t.hold(0.1,frames:20,dt:dt)
            check(t.presses == 0,"closed hand on arrival must not press")
            t.hold(0.6,frames:12,dt:dt)
            t.hold(0.15,frames:12,dt:dt)
            check(t.presses == 1 && t.gesture.isDown,"one stable press")
            t.hold(0.15,frames:60,dt:dt)
            check(t.presses == 1,"holding cannot repeat")
            t.hold(0.6,frames:12,dt:dt)
            check(t.releases == 1 && !t.gesture.isDown,"confirmed release")
            t.hold(0.6,frames:12,dt:dt)
            check(t.releases == 1,"idle cannot repeat release")
            t.hold(0.15,frames:12,dt:dt)
            t.hold(0.6,frames:12,dt:dt)
            check(t.presses == 2 && t.releases == 2,"second cycle needs opening")
        }
        var t = Trace()
        t.hold(0.6,frames:6)
        t.step(0.1);t.step(0.6)
        check(t.presses == 0,"one-frame contact is noise")
        t.hold(0.1,frames:5)
        for ratio in [0.28,0.37,0.41,0.31,0.4,0.35] {t.step(ratio)}
        check(t.gesture.isDown && t.releases == 0,"hysteresis ignores contact jitter")
        t.step(0.6);t.step(0.3)
        check(t.gesture.isDown && t.releases == 0,"one-frame opening cannot release")
        let generation = t.gesture.generation
        t.step(nil,confident:false)
        check(!t.gesture.isDown && t.gesture.generation != generation && t.releases == 0,"loss cancels, never releases")
        t.hold(0.1,frames:20)
        check(t.presses == 1,"closed reacquisition is blocked")
        t.hold(0.6,frames:6);t.hold(0.1,frames:5)
        check(t.presses == 2,"reacquisition requires fresh opening")
        t.step(0.1,grabbing:true)
        check(!t.gesture.isDown && t.releases == 0,"fist cancels click")
        t.hold(0.1,frames:8)
        check(t.presses == 2,"fist release cannot synthesize a press")
        t.hold(0.6,frames:6);t.hold(0.1,frames:5)
        t.step(0.1,dt:0.4)
        check(!t.gesture.isDown && t.releases == 0,"stalled frame delivery cancels")
        t.hold(0.1,frames:8)
        check(t.presses == 3,"no press after stall while closed")
        t.hold(0.6,frames:6);t.step(0.1)
        let time = t.time
        for _ in 0..<100 { t.gesture.update(ratio:0.1,confident:true,at:time) }
        check(t.presses == 3 && !t.gesture.isDown,"duplicate timestamps cannot confirm contact")
        t.gesture.update(ratio:0.1,confident:true,at:time-0.1)
        check(!t.gesture.isDown && !t.gesture.isOpenConfirmed,"time reversal cancels")
        var invalid = StablePinchGesture()
        invalid.update(ratio:.nan,confident:true,at:1)
        check(!invalid.isDown,"NaN ratio cannot press")

        let thumb = SIMD2<Double>(100,100), index = SIMD2<Double>(110,100)
        let wrist = SIMD2<Double>(100,200), base = SIMD2<Double>(100,120), middle = SIMD2<Double>(115,115)
        let one = HandPinchGeometry.measure(thumb:thumb,index:index,wrist:wrist,indexBase:base,middleBase:middle)!
        let two = HandPinchGeometry.measure(thumb:thumb*2,index:index*2,wrist:wrist*2,indexBase:base*2,middleBase:middle*2)!
        check(abs(one.ratio-two.ratio)<1e-12,"ratio invariant to hand/image scale")
        check(HandPinchGeometry.measure(thumb:thumb/20,index:index/20,wrist:wrist/20,indexBase:base/20,middleBase:middle/20) == nil,"tiny hands rejected")
        check(HandPinchGeometry.measure(thumb:SIMD2(.nan,0),index:index,wrist:wrist,indexBase:base,middleBase:middle) == nil,"invalid geometry rejected")

        var ownership = HandInputOwnership()
        func state(_ side: TrackedHand, _ generation: UInt64 = 0, _ down: Bool = false, _ open: Bool = true) -> HandRoutingState {
            HandRoutingState(hand:side,generation:generation,down:down,openConfirmed:open)
        }
        _ = ownership.select(left:state(.left),right:nil)
        var decision = ownership.select(left:state(.left,0,true,false),right:state(.right,0,true,false))
        check(decision.hand == .left && decision.began,"existing hand keeps ownership")
        decision = ownership.select(left:state(.left,0,true,false),right:state(.right))
        check(decision.hand == .left && decision.down && !decision.began,"right appearance cannot steal press")
        decision = ownership.select(left:nil,right:state(.right,0,true,false))
        check(decision.cancel && decision.changedHand && !decision.down,"handoff cancels, held other hand cannot press")
        _ = ownership.select(left:nil,right:state(.right))
        decision = ownership.select(left:nil,right:state(.right,0,true,false))
        check(decision.down && decision.began,"new hand can press after opening")
        decision = ownership.select(left:nil,right:state(.right,1,false,false))
        check(decision.cancel && !decision.down,"quality generation cancels before release")
        decision = ownership.select(left:nil,right:state(.right,1,true,false))
        check(!decision.down,"coalesced loss followed by a closed sample remains blocked")
        _ = ownership.select(left:nil,right:state(.right,1,false,true))
        decision = ownership.select(left:nil,right:state(.right,1,true,false))
        check(decision.down && decision.began,"generation rearms after confirmed opening")
        ownership.suppressUntilOpen()
        decision = ownership.select(left:nil,right:state(.right,1,true,false))
        check(!decision.down,"resize/drag suppression consumes held pinch")
        decision = ownership.select(left:nil,right:nil)
        check(decision.cancel && decision.hand == nil,"loss clears owner")

        var fist = StableFistGesture()
        check(!fist.update(curled:3,known:4,at:0),"fist requires stable evidence")
        check(!fist.update(curled:3,known:4,at:0.033),"single fist frame cannot grab")
        check(fist.update(curled:3,known:4,at:0.08),"stable fist grabs")
        check(fist.update(curled:2,known:4,at:0.1),"fist hysteresis tolerates ambiguity")
        check(!fist.update(curled:3,known:2,at:0.13),"uncertain fist releases, cached joints cannot hold")
        var click = ReleaseClickGate<Int>()
        check(click.update(target:1,down:true,allowBegin:true) == nil,"native down does not execute")
        check(click.update(target:1,down:true,allowBegin:false) == nil,"native hold does not repeat")
        check(click.update(target:1,down:false,allowBegin:false) == 1,"native same-target release executes once")
        check(click.update(target:1,down:false,allowBegin:false) == nil,"native idle release cannot repeat")
        _ = click.update(target:1,down:true,allowBegin:true)
        _ = click.update(target:2,down:true,allowBegin:false)
        _ = click.update(target:1,down:true,allowBegin:false)
        check(click.update(target:1,down:false,allowBegin:false) == nil,"crossing target cancels even after returning")
        _ = click.update(target:1,down:true,allowBegin:true)
        click.cancel()
        check(click.update(target:1,down:false,allowBegin:false) == nil,"tracking loss cancels native action")
        _ = click.update(target:1,down:true,allowBegin:false)
        check(click.update(target:1,down:false,allowBegin:false) == nil,"entering a control while held cannot click")
        _ = click.update(target:1,down:true,allowBegin:true)
        _ = click.update(target:nil,down:true,allowBegin:false)
        check(click.update(target:1,down:false,allowBegin:false) == nil,"missing native target cancels")
        print("PASS: \(checks) native hand gesture checks")
    }
}
