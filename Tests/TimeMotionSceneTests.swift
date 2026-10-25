import Foundation

@main struct SceneTests {
    static func main() {
        var count=0
        func check(_ result:Bool,_ label:String){precondition(result,label);count+=1}
        let game=TimeMotionVRGame(),scene=SCNScene()
        game.start(in:scene,headPosition:.zero,forward:SIMD3(0,0,-1))
        check(game.phase == .ready && game.enemies.count == 8,"full arena starts in practice until gun pickup")
        let nodeCount=game.root.childNodes.count
        var now=0.0
        func frame(_ left:TimeMotionHandInput?=nil,_ right:TimeMotionHandInput?=nil,ready:Bool=true,head:SIMD3<Float> = .zero) {
            var matrix=simd_float4x4();matrix.columns.3=SIMD4(head.x,head.y,head.z,1)
            game.update(now:now,left:left,right:right,headTransform:matrix,trackingReady:ready,dwell:true)
            now += 1/60
        }
        func hand(_ which:TrackedHand = .right,open:Bool=false,fist:Bool=true,generation:UInt64=1,point:SIMD3<Float> = SIMD3(0,-0.2,-0.5),aim:SIMD3<Float>?=nil)->TimeMotionHandInput {
            var points=[SIMD3<Float>?](repeating:nil,count:21)
            points[0]=point-SIMD3(0,0.03,0);points[9]=point+SIMD3(0,0.03,0)
            points[5]=point+SIMD3(0.035,0.02,0);points[17]=point+SIMD3(-0.035,0.02,0)
            let pose=VirtualHandPose(points:points,camera:.zero)!
            let direction=aim ?? simd_normalize(game.items[0].position)
            return TimeMotionHandInput(hand:which,timestamp:now,pose:pose,aimRay:WorldRay(origin:.zero,direction:direction),trackingGeneration:generation,fist:fist,open:open,pinch:false)
        }
        for _ in 0..<120 { frame() }
        check(game.enemies.allSatisfy{!$0.alive},"no enemies attack during onboarding")
        for _ in 0..<15 { frame(nil,hand()) }
        check(game.items[0].held == .right && game.phase == .playing,"actual fist latch grabs pistol and starts round")
        for _ in 0..<200 { frame(nil,hand(aim:SIMD3(0,0,-1))) }
        check(game.sounds.events.contains(.shot),"held pistol automatically fires in slow game time")
        let shots=game.sounds.events.filter{$0 == .shot}.count
        frame(nil,hand(open:true,fist:false,aim:SIMD3(0,0,-1)))
        check(!game.gunFiring,"opening the palm stops fire on the first frame")
        for _ in 0..<121 { frame(nil,hand(open:true,fist:false,aim:SIMD3(0,0,-1))) }
        check(game.items[0].held == nil,"continuous open palm releases after two seconds")
        check(game.sounds.events.filter{$0 == .shot}.count == shots,"release countdown emits no shots")
        game.resetRound()
        for _ in 0..<15 {frame(nil,hand())}
        frame(nil,hand(generation:2))
        check(game.items[0].held == nil && !game.gunFiring,"new tracking identity cannot inherit held gun or firing")
        game.resetRound()
        for _ in 0..<15 {frame(nil,hand())}
        frame(nil,nil,ready:false)
        check(game.timeScale.scale == 0 && !game.gunFiring,"camera loss immediately freezes game and fire")
        check(game.items[0].position == game.items[0].home,"lost weapon returns to accessible stand")
        game.resetRound()
        for _ in 0..<15 {frame(nil,hand())}
        game.handleButton(0)
        let score=game.score.points,clock=game.clock.gameTime
        for _ in 0..<60 {frame(nil,hand(aim:SIMD3(0,0,-1)))}
        check(game.clock.gameTime == clock && game.score.points == score && !game.gunFiring,"paused hands cannot fire, damage or advance time")
        game.handleButton(0)
        for i in 0..<60 {frame(nil,hand(aim:SIMD3(0,0,-1)),head:SIMD3(Float(i)*0.008,0,0))}
        check(game.timeScale.scale > 0.8,"leaning without head rotation accelerates time")
        let anchored=game.place(4,1,0)
        frame(head:SIMD3(1,0,0))
        check(game.place(4,1,0)==anchored,"arena and spawn positions never follow the moving player")
        game.resetRound();game.phase = .playing
        let enemy=game.enemies[0];enemy.spawn(at:game.place(4,0,0),approaches:false,firstShot:99)
        _=game.spawnBullet(owner:.player,position:enemy.targets[1].center+SIMD3(0,0,0.5),velocity:SIMD3(0,0,-30),lifetime:2)
        for _ in 0..<5 {game.updateBullets(1/120)}
        check(!enemy.alive && game.score.points == 100,"a swept head shot kills the actual enemy once")
        game.killEnemy(enemy)
        check(game.score.points == 100,"dead enemy cannot give duplicate score")
        game.resetRound();game.phase = .playing
        for _ in 0..<6000 {
            if game.phase != .playing {break}
            game.simulateStep(1/120)
            for target in game.enemies where target.alive {
                let aim=target.targets[1].center
                _=game.spawnBullet(owner:.player,position:aim+SIMD3(0,0,0.1),velocity:SIMD3(0,0,-30),lifetime:1)
            }
        }
        check(game.phase == .victory && game.score.points == 2750,"three actual waves finish with victory and correct total score")
        check(game.buttons[0].node.isHidden && !game.buttons[2].node.isHidden,"victory offers a working replay button")
        game.handleButton(2)
        check(game.phase == .ready && game.score.points == 0 && game.health.remaining == 3,"replay resets lives, score and onboarding")
        game.recenterControls(head:SCNNode())
        check(!game.userPaused,"recentering before grabbing the pistol cannot block starting the game")
        game.phase = .playing
        for _ in 0..<3 {game.playerTime += 1;game.playerHit()}
        check(game.phase == .defeat && !game.gunFiring,"three separated hits end the round and stop firing")
        for _ in 0..<20 {game.resetRound();check(game.root.childNodes.count == nodeCount && Set(game.freeBulletSlots).count == 32,"restart reuses bounded scene and bullet pool")}
        game.stop();check(scene.rootNode.childNodes.isEmpty,"stop detaches arena")
        game.start(in:scene,headPosition:SIMD3(3,0,4),forward:SIMD3(1,0,0))
        check(game.place(4,0,0).x == 7,"re-entry anchors arena to new position and heading")
        let box=game.coverBoxes[0],c=(box.lo+box.hi)*0.5
        check(TimeMotionGeometry.hitBox(from:c-game.forward,to:c+game.forward,box:box) != nil,"rotated rendered cover has matching collision")
        print("PASS: \(count) production Time Motion scene, input, lifecycle, firing and damage checks")
    }
}
