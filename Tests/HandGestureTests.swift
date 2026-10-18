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
        var noisy = Trace()
        noisy.hold(0.6,frames:6)
        for ratio in [0.29,0.32,0.28,0.33] { noisy.step(ratio) }
        check(noisy.presses == 1,"small contact jitter above close threshold must not reset press confirmation")
        noisy.hold(0.6,frames:4)
        check(noisy.releases == 1,"noisy contact still requires a confirmed release")
        var dwell = DwellClickGate<Int>()
        var clicks = 0
        for i in 0...60 { if dwell.update(target:1,at:Double(i)/30) != nil { clicks += 1 } }
        check(clicks == 1,"two seconds over one button fires once")
        _ = dwell.update(target:nil,at:2.1)
        for i in 0...30 { if dwell.update(target:1,at:2.2+Double(i)/30) != nil { clicks += 1 } }
        check(clicks == 2,"leaving and returning rearms dwell")
        dwell.cancel()
        for i in 0...25 { _ = dwell.update(target:1,at:4+Double(i)/30) }
        check(dwell.update(target:1,at:6) == nil && dwell.progress == 0,"lost frames cannot finish a dwell")
        _ = dwell.update(target:2,at:6.1)
        check(dwell.progress == 0,"moving to another target resets progress")
        dwell.cancel()
        check(dwell.update(target:2,at:6.2) == nil,"hand switch/cancel requires a complete new dwell")
        check(dwell.update(target:2,at:.nan) == nil && dwell.progress == 0,"invalid dwell timestamp cancels")
        var modeGate=ReleaseClickGate<Int>()
        _ = modeGate.update(target:1,down:true,allowBegin:true)
        check(modeGate.update(target:1,down:false,allowBegin:false,dwell:true,at:0) == nil,"mode switch cannot release an old pinch as a click")
        for i in 1...20 { _ = modeGate.update(target:1,down:false,allowBegin:false,dwell:true,at:Double(i)/30) }
        check(modeGate.update(target:1,down:true,allowBegin:true,dwell:true,at:0.7) == nil && modeGate.dwellProgress == 0,"scroll pinch cancels dwell progress")
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

        check(!HandGestureIntent.allowsFist(indexCurled:true,curled:4,known:4,pinchRatio:0.16,pinchEngaged:false),
              "curled fingers with thumb/index contact remain a pinch")
        check(!HandGestureIntent.allowsFist(indexCurled:true,curled:4,known:4,pinchRatio:0.6,pinchEngaged:true),
              "opening a pinch cannot turn it into a fist before release")
        check(HandGestureIntent.allowsFist(indexCurled:true,curled:4,known:4,pinchRatio:0.6,pinchEngaged:false),
              "separated thumb/index and curled fingers can grab")
        check(HandGestureIntent.allowsFist(indexCurled:true,curled:4,known:4,pinchRatio:nil,pinchEngaged:false),
              "occluded tips do not disable a confident fist")
        check(!HandGestureIntent.allowsFist(indexCurled:nil,curled:3,known:3,pinchRatio:nil,pinchEngaged:false),
              "unknown index cannot start a fist")
        check(HandGestureIntent.allowsFist(indexCurled:true,curled:4,known:4,pinchRatio:0.1,
              pinchEngaged:true,indexFoldedIntoPalm:true),"fully folded fist cancels a pinch even with thumb/index contact")

        // Real closing/holding/opening traces with a bending fingertip and a
        // stationary palm must stay on a 12 px button hit target throughout.
        for fps in [15.0,20,30,60] {
            var gesture = StablePinchGesture(), aim = PinchAimStabilizer()
            var time = 0.0
            let palm = SIMD2<Double>(0.45,0.5), target = SIMD2<Double>(0.5,0.4)
            var began: SIMD2<Double>?, ended: SIMD2<Double>?
            var maxDrift = 0.0
            for (ratio,offset) in [(0.6,0.0),(0.35,0.03),(0.15,0.06),(0.15,0.08),(0.6,-0.03)] {
                for _ in 0..<Int(fps*0.2) {
                    time += 1/fps
                    let event = gesture.update(ratio:ratio,confident:true,at:time)
                    let approaching = gesture.isOpenConfirmed && ratio < gesture.configuration.openRatio
                    let point = aim.update(index:target+SIMD2(offset,0),palm:palm,
                        engaged:gesture.isEngaged || approaching,released:event == .released)
                    if event == .pressed { began = point }
                    if gesture.isDown { maxDrift = max(maxDrift,HandPinchGeometry.distance(point,target)) }
                    if event == .released { ended = point }
                }
            }
            check(began == target && ended == target && maxDrift < 1e-12,
                  "finger articulation cannot scroll or move a click off Safari")
            let next = aim.update(index:SIMD2(0.8,0.4),palm:palm,engaged:false)
            check(next == SIMD2(0.8,0.4),"hover resumes after release")
            _ = aim.update(index:target,palm:palm,engaged:false)
            _ = aim.update(index:target,palm:palm,engaged:true)
            let dragged = aim.update(index:target,palm:palm+SIMD2(0,0.1),engaged:true)
            check(HandPinchGeometry.distance(dragged,target+SIMD2(0,0.1)) < 1e-12,
                  "deliberate palm movement still scrolls/drags")
            aim.reset()
            check(aim.update(index:target,palm:palm,engaged:false) == target,"loss clears captured aim")
        }

        let fingerBases = [SIMD2<Double>(144,172),SIMD2(130,120),SIMD2(107,113),SIMD2(84,119),SIMD2(65,130)]
        let fingers: [[SIMD2<Double>?]] = fingerBases.enumerated().map { n,p in
            (0..<4).map { p+SIMD2(Double(n == 0 ? $0*12 : 0),Double(-$0*24)) }
        }
        let silhouette = HandSilhouette.make(wrist:SIMD2(105,200),fingers:fingers)!
        let doubled = HandSilhouette.make(wrist:SIMD2(210,400),fingers:fingers.map { $0.map { $0.map { $0*2 } } })!
        check(silhouette.segments.count == 15,"all five complete fingers have bounded segments")
        check(zip(silhouette.segments,doubled.segments).allSatisfy {
            abs($0.startRadius*2-$1.startRadius)<1e-12 && $0.start*2 == $1.start
        },"mask scales exactly with camera-space hand size")
        check(silhouette.segments.allSatisfy { $0.endRadius < $0.startRadius },"all fingers taper toward their tips")
        check(silhouette.segments[3].startRadius < 10,"normal 90 px palm cannot create a 100 px wide cutout")
        let indexEdge = silhouette.segments[3].start.x-silhouette.segments[3].startRadius
        let middleEdge = silhouette.segments[6].start.x+silhouette.segments[6].startRadius
        check(indexEdge > middleEdge,"open index/middle finger gap stays visible")
        var partial = fingers
        partial[1][2] = nil
        let missing = HandSilhouette.make(wrist:SIMD2(105,200),fingers:partial)!
        check(missing.segments.count == 13,"missing joint cannot leave a cached bridge or disc")
        partial[4][0] = nil
        check(HandSilhouette.make(wrist:SIMD2(105,200),fingers:partial) == nil,"missing palm anchors cannot cut a broad hole")
        check(HandSilhouette.make(wrist:SIMD2(10.5,20),fingers:fingers.map { $0.map { $0.map { $0*0.1 } } }) == nil,
              "tiny uncertain hand does not expand to a fixed minimum width")
        print("PASS: \(checks) native hand gesture checks")
    }
}
