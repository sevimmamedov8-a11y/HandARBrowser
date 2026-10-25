import Foundation

@main struct FlightTests {
    static func main() {
        var count=0
        func check(_ value:Bool,_ message:String){precondition(value,message);count+=1}
        var steering=NeonFlightSteering()
        for i in 0...30 {let t=Double(i)/60;steering.update(yaw:0,pitch:0,stamp:t,now:t,ready:true,dt:1/60)}
        check(steering.safe && steering.control == .zero,"stable neutral head becomes ready without drift")
        for i in 31...60 {let t=Double(i)/60;let yaw=min(0.35,Double(i-30)*0.02);steering.update(yaw:yaw,pitch:0,stamp:t,now:t,ready:true,dt:1/60)}
        check(steering.control.x>0.95 && abs(steering.control.y)<0.01,"twenty-degree right turn fully steers right")
        steering.update(yaw:0.35,pitch:0,stamp:1,now:1.3,ready:true,dt:1/60)
        check(!steering.safe && steering.control == .zero,"stale capture cannot continue steering")
        for i in 0...30 {let t=2+Double(i)/60;steering.update(yaw:0.2,pitch:0.1,stamp:t,now:t,ready:true,dt:1/60)}
        steering.calibrate(yaw:0.2,pitch:0.1)
        check(steering.control == .zero,"calibration sets the current look as neutral")
        steering.update(yaw:2,pitch:0,stamp:2.52,now:2.52,ready:true,dt:1/60)
        check(!steering.safe,"tracking jump freezes input")
        var repeated=NeonFlightSteering()
        for i in 0..<60 {
            let now=3+Double(i)/60,stamp=3+Double(i/2)/30
            repeated.update(yaw:0,pitch:0,stamp:stamp,now:now,ready:true,dt:1/60)
        }
        check(repeated.safe && repeated.control == .zero,"30 Hz camera on 60 Hz display preserves neutral input")
        var run=NeonFlightRun(seed:12)
        check(run.items.count<32 && run.items.first?.kind == .ring,"course starts with approachable rings and bounded lookahead")
        let first=run.items
        run.advance(dt:0,control:.zero)
        check(run.distance==0 && run.items.map{$0.distance}==first.map{$0.distance},"zero-time pause leaves the course exactly still")
        run.advance(dt:.nan,control:SIMD2(1,1));check(run.distance==0,"invalid clock does not corrupt gameplay")
        var sixty=NeonFlightRun(seed:7),thirty=sixty
        for _ in 0..<600 {sixty.advance(dt:1/60,control:SIMD2(0.1,0.1))}
        for _ in 0..<300 {thirty.advance(dt:1/30,control:SIMD2(0.1,0.1))}
        check(abs(sixty.distance-thirty.distance)<0.05 && sixty.score==thirty.score && sixty.hull==thirty.hull,"flight speed and collisions are consistent at 30 and 60 FPS")
        run=NeonFlightRun();run.items=[NeonFlightItem(id:999,kind:.ring,lane:.zero,distance:0.02,phase:0)]
        run.advance(dt:1/60,control:.zero)
        check(run.score==100 && run.rings==1,"crossing a ring awards a single score")
        run.advance(dt:1/60,control:.zero);check(run.score==100,"same ring cannot score twice")
        for index in 0..<3 {
            run.items=[NeonFlightItem(id:1000+index,kind:.energy,lane:.zero,distance:0.02,phase:0)]
            run.advance(dt:1/60,control:.zero)
        }
        check(run.shields==1 && run.energy==0,"three energy pickups charge a shield")
        run.items=[NeonFlightItem(id:2000,kind:.gate,lane:SIMD2(3,0),distance:0.02,phase:0)]
        run.advance(dt:1/60,control:.zero)
        check(run.hull==3 && run.shields==0,"shield absorbs one obstacle without damaging hull")
        for hit in 0..<3 {
            run.invulnerable=0
            run.items=[NeonFlightItem(id:2100+hit,kind:.gate,lane:SIMD2(3,0),distance:0.02,phase:0)]
            run.advance(dt:1/60,control:.zero)
        }
        check(run.hull==0 && run.ended,"three unshielded hits end the run")
        let stopped=run.distance;run.advance(dt:0.1,control:SIMD2(1,1))
        check(run.distance==stopped,"game-over cannot keep moving or scoring")
        var autopilot=NeonFlightRun(seed:55),charged=false,peak=0
        for _ in 0..<18000 {
            guard !autopilot.ended else {break}
            let target=autopilot.items.filter{$0.kind == .ring && $0.distance>0}.min{$0.distance<$1.distance}!.lane
            let delta=target-autopilot.position
            autopilot.advance(dt:1/120,control:delta*2)
            charged = charged || autopilot.events.contains(.shield);peak=max(peak,autopilot.items.count)
        }
        check(autopilot.distance>600 && autopilot.score>1500,"generated course stays playable across all three environments")
        check(charged && peak<32,"procedural energy is collectable and object count remains bounded")
        check(NeonFlightProgress.ships(0)==1 && NeonFlightProgress.ships(500)==2 && NeonFlightProgress.ships(1500)==3,"records unlock three ship variants")
        let suite="flight.tests.\(UUID())",defaults=UserDefaults(suiteName:suite)!
        NeonFlightProgress.record(600,defaults:defaults);NeonFlightProgress.record(50,defaults:defaults)
        check(NeonFlightProgress.best(defaults)==600,"lower scores cannot overwrite the best run")
        defaults.removePersistentDomain(forName:suite)
        let game=NeonFlightGame(),scene=SCNScene(),head=SCNNode()
        game.start(in:scene,head:head)
        let nodes=game.world.childNodes.count
        var now=0.0
        func frame(ready:Bool=true){game.update(now:now,head:head,stamp:now,ready:ready);now+=1/60}
        for _ in 0..<40 {frame()}
        check(game.trackingSafe && game.mode == .menu,"scene waits for stable head tracking before starting")
        let buttonDirection=simd_normalize(game.buttons[0].simdPosition)
        for index in 1...20 {
            let t=Float(index)/20,dir=simd_normalize(SIMD3<Float>(0,0,-1)*(1-t)+buttonDirection*t)
            head.simdWorldTransform.columns.2=SIMD4(-dir.x,-dir.y,-dir.z,0);frame()
        }
        for _ in 0..<75 {frame()}
        check(game.mode == .countdown,"looking at Play alone commits the dwell button")
        for index in 1...20 {
            let t=Float(index)/20,dir=simd_normalize(buttonDirection*(1-t)+SIMD3<Float>(0,0,-1)*t)
            head.simdWorldTransform.columns.2=SIMD4(-dir.x,-dir.y,-dir.z,0);frame()
        }
        for _ in 0..<185 {frame()}
        check(game.mode == .flying && game.run.distance>0,"head-menu start performs countdown and launches the actual scene")
        for _ in 0..<100 {frame()}
        game.action(0,head:head);let pausedDistance=game.run.distance
        for _ in 0..<60 {frame()}
        check(game.mode == .paused && game.run.distance==pausedDistance,"pause freezes the actual course")
        game.action(0,head:head)
        for _ in 0..<182 {frame()}
        check(game.mode == .flying && game.run.distance>=pausedDistance,"resume keeps distance and score instead of resetting the run")
        frame(ready:false);let lostDistance=game.run.distance
        check(game.mode == .paused && !game.trackingSafe,"tracking loss immediately pauses the running scene")
        for _ in 0..<60 {frame()}
        check(game.run.distance==lostDistance,"tracking recovery cannot resume flight without confirmation")
        game.recenter(head:head)
        check(game.mode == .paused && !game.steering.safe,"recenter requires a stable new neutral pose")
        for _ in 0..<10 {game.mode = .over;game.action(0,head:head);game.countdown=0;for _ in 0..<30{frame()}}
        check(game.world.childNodes.count==nodes && game.visuals.count==44,"replays reuse scene geometry and bounded item pools")
        var exited=false;game.onExit={exited=true};game.action(2,head:head)
        check(exited,"exit button invokes the host lifecycle")
        game.stop();check(scene.rootNode.childNodes.isEmpty,"stop removes the full flight scene")
        print("PASS: \(count) production Neon Flight steering, rings, shields, collisions, progression and scene lifecycle checks")
    }
}
