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
        for i in 0..<200 { frame(nil,hand(point:SIMD3(0.05*sin(Float(i)*0.15),-0.2,-0.5),aim:SIMD3(0,0,-1))) }
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
        for i in 0..<60 {frame(nil,hand(aim:SIMD3(0,0,-1)),head:SIMD3(Float(i)*0.012,0,0))}
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
        for _ in 0..<20 {game.resetRound();check(game.root.childNodes.count == nodeCount && Set(game.freeBulletSlots).count == TMLayout.bulletPoolSize,"restart reuses bounded scene and bullet pool")}
        // V104: new mechanics exercise production methods, not copied game rules.
        check((game.floorNode.geometry as? SCNPlane)?.width == 32 && (game.floorNode.geometry as? SCNPlane)?.height == 24,"arena floor is four times the former 16 by 12 area")
        check(game.items[4].kind == .pistol && game.items[5].kind == .shotgun && game.items[6].kind == .katana,"weapon rack offers second pistol, shotgun and katana")
        let roomCover = game.coverBoxes
        game.coverBoxes = [] // Isolate combat contacts from arena cover in the following fixtures.
        game.resetRound();game.phase = .playing;game.head = .zero
        let pistol = game.items[0],second = game.items[4],shotgun = game.items[5],sword = game.items[6]
        pistol.held = .right;pistol.position = SIMD3(0,-0.2,-0.5);pistol.aim = SIMD3(0,0,-1)
        for _ in 0..<20 {game.fireGun(pistol)}
        check(pistol.ammo == 0 && game.bullets.count == 12,"pistol stops at twelve rounds, never fires empty")
        second.held = .left;second.position = SIMD3(-0.3,-0.2,-0.5);game.fireGun(second)
        check(second.ammo == 11 && pistol.ammo == 0 && game.bullets.count == 13,"two hands use independent magazines")
        game.returnItem(0);check(pistol.ammo == 0,"losing a hand cannot refill an empty magazine")
        game.resetRound();game.phase = .playing
        shotgun.held = .right;shotgun.position = SIMD3(0,-0.3,-0.5);shotgun.aim = SIMD3(0,1,0)
        game.fireGun(shotgun)
        check(shotgun.ammo == 5 && game.bullets.count == 5,"one shotgun shell emits five pellets even aiming vertically")
        check(game.bullets.allSatisfy { $0.state.velocity.x.isFinite && $0.state.velocity.y.isFinite && $0.state.velocity.z.isFinite },"vertical aiming never creates NaN trajectories")
        check(game.bullets.allSatisfy { simd_length($0.state.position-shotgun.muzzle)<0.001 },"shotgun pellets originate at the long muzzle")
        game.resetRound();game.phase = .playing
        pistol.held = .right;pistol.position = SIMD3(0,0,-0.5)
        game.coverBoxes = [BoxObstacle(lo:SIMD3(-1,-1,-0.6),hi:SIMD3(1,1,-0.55))]
        game.fireGun(pistol)
        check(game.bullets.isEmpty && pistol.ammo == 12,"barrel crossing cover cannot shoot through it")
        game.coverBoxes = []
        game.resetRound();game.phase = .playing;game.head = .zero
        sword.held = .right;sword.position = SIMD3(0,0,-0.35);sword.aim = SIMD3(0,0,-1)
        _ = game.spawnBullet(owner:.enemy,position:SIMD3(0,0,-1.2),velocity:SIMD3(0,0,30),lifetime:2)
        for _ in 0..<6 {game.updateBullets(1/120)}
        check(game.bullets.isEmpty && game.health.remaining == 3,"held katana blocks a bullet before it reaches the head")
        game.resetRound();game.phase = .playing
        enemy.spawn(at:SIMD3(3,game.floorY,-3),approaches:false,firstShot:99)
        game.killEnemy(enemy)
        let loot = game.items[TMLayout.lootStart]
        check(loot.available && loot.ammo == 12 && !loot.resting,"defeated enemy drops a loaded throwable weapon")
        loot.held = .left;loot.ammo = 3;let heldLootPosition = loot.position
        enemy.spawn(at:SIMD3(4,game.floorY,-3),approaches:false,firstShot:99);game.killEnemy(enemy)
        check(loot.position == heldLootPosition && loot.ammo == 3,"pool reuse cannot teleport or refill a gun already held")
        game.resetRound();game.phase = .playing
        enemy.spawn(at:SIMD3(3,game.floorY,-5),approaches:false,firstShot:99);enemy.role = 0
        let oldEnemy = enemy.position
        game.updateEnemies(0.1)
        check(simd_length(enemy.position-game.head)<simd_length(oldEnemy-game.head),"rusher actively closes distance")
        enemy.spawn(at:SIMD3(0,game.floorY,-4),approaches:false,firstShot:99);enemy.role = 1
        game.updateEnemies(0.1)
        check(abs(enemy.position.x)>0.04,"strafer moves sideways across the firing line")
        enemy.move(to:SIMD3(0,game.floorY,0));game.updateEnemies(0.1)
        check(enemy.position.x.isFinite && enemy.position.z.isFinite,"enemy at player position has a finite escape direction")
        game.resetRound();game.phase = .playing
        enemy.spawn(at:SIMD3(0,-1.06,-0.85),approaches:false,firstShot:99)
        sword.held = .right;sword.aim = SIMD3(0,0,-1)
        game.strike(from:SIMD3(-0.1,0,-0.5),to:SIMD3(0.1,0,-0.5),blade:sword,hand:1,speed:1.2,now:now)
        check(!enemy.alive,"swinging the blade hits along its length, not only at its tip")
        game.resetRound();game.phase = .playing
        enemy.spawn(at:SIMD3(0,-1.06,-1.1),approaches:false,firstShot:99)
        game.coverBoxes = [BoxObstacle(lo:SIMD3(-1,-1,-0.65),hi:SIMD3(1,1,-0.6))]
        game.strike(from:SIMD3(-0.1,0,-0.5),to:SIMD3(0.1,0,-0.5),blade:sword,hand:1,speed:1.2,now:now+1)
        check(enemy.alive,"katana cannot reach through cover")
        game.coverBoxes = [];enemy.die()
        let aimPose = hand(aim:SIMD3(0,0,-1)).pose!
        game.placeHeld(pistol,pose:aimPose,ray:WorldRay(origin:.zero,direction:SIMD3(0,0,-1)),hand:.right)
        let towardTarget = SIMD3<Float>(0,0,-20)-pistol.position
        check(pistol.position.x>aimPose.center.x && pistol.position.y<aimPose.center.y,"held pistol moves below and outside the aim line")
        check(simd_length(simd_cross(pistol.aim,simd_normalize(towardTarget)))<0.001,"lowered muzzle still aims at the hand-ray target")
        game.mode = .headshots;game.resetRound();game.phase = .playing
        enemy.spawn(at:SIMD3(0,game.floorY,-4),approaches:false,firstShot:99)
        let torso = enemy.targets[0].center
        _ = game.spawnBullet(owner:.player,position:torso+SIMD3(0,0,0.4),velocity:SIMD3(0,0,-30),lifetime:1)
        for _ in 0..<4 {game.updateBullets(1/120)}
        check(enemy.alive,"headshots challenge ignores torso hits")
        let skull = enemy.targets[1].center
        _ = game.spawnBullet(owner:.player,position:skull+SIMD3(0,0,0.4),velocity:SIMD3(0,0,-30),lifetime:1)
        for _ in 0..<4 {game.updateBullets(1/120)}
        check(!enemy.alive,"headshots challenge accepts a head hit")
        game.mode = .hardcore;game.resetRound();game.phase = .playing;game.playerHit()
        check(game.phase == .defeat,"hardcore ends on one hit")
        game.refreshHUD(now:now,effectiveScale:0)
        check(game.healthLabel.text.contains("0 из 1"),"hardcore HUD displays its actual life limit")
        game.mode = .waves;game.resetRound();game.handleButton(3)
        check(game.mode == .endless && game.director.endless && game.phase == .ready,"mode button activates endless and resets the round")
        game.mode = .waves;game.resetRound();game.phase = .playing
        for _ in 0..<30 {frame()}
        enemy.spawn(at:SIMD3(3,game.floorY,-6),approaches:true,firstShot:0.1)
        _ = game.spawnBullet(owner:.enemy,position:SIMD3(2,0,-2),velocity:SIMD3(0,0,4.5),lifetime:6)
        game.spawnShards(at:SIMD3(2,0,-3))
        let prop = game.items[1];prop.resting = false;prop.velocity = SIMD3(1,2,0)
        game.syncNodes()
        let frozenTime = game.clock.gameTime,bulletPosition = game.bullets[0].state.position
        let enemyPosition = enemy.position,propPosition = prop.position,shardPosition = game.shards[0].node.simdPosition
        for _ in 0..<180 {frame()}
        check(game.clock.gameTime == frozenTime && game.timeScale.scale == 0,"remaining still freezes game time for three real seconds")
        check(game.bullets[0].state.position == bulletPosition && enemy.position == enemyPosition,"bullets and enemies remain exactly still")
        check(prop.position == propPosition && game.shards[0].node.simdPosition == shardPosition,"thrown items and debris obey the same freeze")
        for i in 1...30 {frame(head:SIMD3(Float(i)*0.01,0,0))}
        check(game.clock.gameTime>frozenTime && enemy.position != enemyPosition,"moving again resumes the frozen simulation")
        game.coverBoxes = roomCover
        game.stop();check(scene.rootNode.childNodes.isEmpty,"stop detaches arena")
        game.start(in:scene,headPosition:SIMD3(3,0,4),forward:SIMD3(1,0,0))
        check(game.place(4,0,0).x == 7,"re-entry anchors arena to new position and heading")
        let box=game.coverBoxes[0],c=(box.lo+box.hi)*0.5
        check(TimeMotionGeometry.hitBox(from:c-game.forward,to:c+game.forward,box:box) != nil,"rotated rendered cover has matching collision")
        print("PASS: \(count) production Time Motion scene, input, lifecycle, firing and damage checks")
    }
}
