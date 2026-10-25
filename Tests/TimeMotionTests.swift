import Foundation

@main struct TimeMotionTests {
    static func main() {
        var count = 0
        func check(_ result: Bool, _ label: String) {
            precondition(result, label)
            count += 1
        }
        let dt60 = 1.0 / 60.0
        let fixed = TimeMotionTuning.fixedStep

        // MARK: Time scale

        var still = TimeScaleController()
        for _ in 0..<120 { still.update(.motion(head: 2.0, hand: 0.6), realDt: dt60) }
        check(still.scale > 0.95, "fast head and hand motion reaches full game speed")
        for _ in 0..<180 { still.update(.motion(head: 0, hand: 0), realDt: dt60) }
        check(still.scale < 0.1 && !still.isPaused, "keeping still slows time to a crawl without pausing")

        var jitter = TimeScaleController()
        for _ in 0..<600 { jitter.update(.motion(head: 0.1, hand: 0.02), realDt: dt60) }
        check(abs(jitter.scale - TimeMotionTuning.minimumScale) < 1e-9, "sensor jitter below the noise floor is ignored")

        var glitch = TimeScaleController()
        for _ in 0..<120 { glitch.update(.motion(head: 2.0, hand: 0.6), realDt: dt60) }
        for _ in 0..<60 { glitch.update(.motion(head: 20, hand: 0), realDt: dt60) }
        check(glitch.scale == 0 && glitch.isPaused, "a tracking jump immediately freezes gameplay")
        for _ in 0..<60 { glitch.update(.glitch, realDt: dt60) }
        check(glitch.isPaused && glitch.scale == 0, "unreliable camera poses cannot advance gameplay")

        var lost = TimeScaleController()
        for _ in 0..<120 { lost.update(.motion(head: 2.0, hand: 0.6), realDt: dt60) }
        for _ in 0..<6 { lost.update(.lost, realDt: dt60) }
        check(lost.isPaused, "even a short camera tracking gap pauses damage and time")
        for _ in 0..<9 { lost.update(.lost, realDt: dt60) }
        check(lost.isPaused && lost.scale == 0, "losing tracking for 0.25 s pauses the game completely")
        lost.update(.motion(head: 2.0, hand: 0), realDt: dt60)
        check(!lost.isPaused && lost.scale < 0.25, "after recovery time resumes slowly, not from the last speed")

        var invalid = TimeScaleController()
        invalid.update(.motion(head: .nan, hand: 0), realDt: dt60)
        invalid.update(.motion(head: 1, hand: 0), realDt: .infinity)
        check(invalid.scale.isFinite && invalid.scale >= 0, "NaN and infinite inputs cannot corrupt the scale")

        // MARK: Fixed-step clock

        var sixty = FixedStepClock()
        var oneforty = FixedStepClock()
        for _ in 0..<60 { _ = sixty.advance(realDt: 1.0 / 60.0, scale: 0.5) }
        for _ in 0..<144 { _ = oneforty.advance(realDt: 1.0 / 144.0, scale: 0.5) }
        check(abs(sixty.gameTime - oneforty.gameTime) <= 2 * fixed, "game time does not depend on frame rate")
        check(abs(sixty.gameTime - 0.5) <= 2 * fixed, "one real second at half speed is half a game second")

        var stall = FixedStepClock()
        let stallSteps = stall.advance(realDt: 5, scale: 1)
        check(stallSteps <= TimeMotionTuning.maxStepsPerFrame && stall.gameTime <= 0.1 + 1e-9,
              "a stall advances at most the capped step and drops the backlog")

        var paused = FixedStepClock()
        check(paused.advance(realDt: 1, scale: 0) == 0 && paused.gameTime == 0, "scale 0 stops game time")

        // MARK: Fire scheduler

        var trigger = FireScheduler()
        var shots = 0
        for _ in 0..<120 where trigger.advance(gameDt: fixed, firing: true) { shots += 1 }
        check(shots == 3 || shots == 4, "held trigger fires about every 0.28 game seconds")

        var released = FireScheduler()
        for _ in 0..<240 { _ = released.advance(gameDt: fixed, firing: false) }
        var firstShot = -1
        var burst = 0
        for step in 0..<30 where released.advance(gameDt: fixed, firing: true) {
            if firstShot < 0 { firstShot = step }
            burst += 1
        }
        check(firstShot >= 13 && firstShot <= 16, "re-arming after a release waits, it does not fire at once")
        check(burst == 1, "a quarter second of holding after re-arm gives one shot, never a queued burst")

        var frozen = FireScheduler()
        var frozenShots = 0
        for _ in 0..<200 where frozen.advance(gameDt: 0, firing: true) { frozenShots += 1 }
        check(frozenShots == 0, "a paused game (zero game time) never fires")

        // MARK: Swept geometry

        let fast = TimeMotionGeometry.segmentSphere(from: SIMD3(0, 0, 0), to: SIMD3(1, 0, 0),
                                                    center: SIMD3(0.5, 0, 0), radius: 0.05)
        check(fast != nil && abs((fast ?? 0) - 0.45) < 0.001, "a bullet crossing a target between frames is caught")
        check(TimeMotionGeometry.length(SIMD3<Float>(1, 0, 0) - SIMD3(0.5, 0, 0)) > 0.05, "endpoints alone would have missed the target")

        let boxHit = TimeMotionGeometry.segmentBox(from: SIMD3(-1, 0.5, 0), to: SIMD3(1, 0.5, 0),
                                                   min: SIMD3(-0.2, 0, -0.2), max: SIMD3(0.2, 1, 0.2))
        check(boxHit != nil && abs((boxHit ?? 0) - 0.4) < 0.001, "a box blocks a segment at its near face")
        check(TimeMotionGeometry.segmentBox(from: SIMD3(-1, 2, 0), to: SIMD3(1, 2, 0),
                                            min: SIMD3(-0.2, 0, -0.2), max: SIMD3(0.2, 1, 0.2)) == nil,
              "a segment passing above the box misses it")
        check(TimeMotionGeometry.segmentSphere(from: SIMD3(0, 0, 0), to: SIMD3(0.1, 0, 0),
                                               center: SIMD3(2, 0, 0), radius: 0.05) == nil,
              "a short step that does not reach a target misses it")

        // MARK: Impact ownership

        let enemy = SphereTarget(id: 7, center: SIMD3(0.5, 0, 0), radius: 0.15)
        let head = SphereTarget(id: -1, center: SIMD3(0.5, 0, 0), radius: TimeMotionTuning.playerHeadRadius)
        let cover = BoxObstacle(lo: SIMD3(0.2, -1, -1), hi: SIMD3(0.3, 1, 1))

        let enemyBulletPassesEnemy = ProjectileRules.firstImpact(owner: .enemy, from: SIMD3(0, 0, 0), to: SIMD3(1, 0, 0),
                                                                covers: [], enemies: [enemy], playerHead: nil)
        check(enemyBulletPassesEnemy == nil, "enemy bullets never hit other enemies")

        let playerBulletPassesPlayer = ProjectileRules.firstImpact(owner: .player, from: SIMD3(0, 0, 0), to: SIMD3(0.4, 0, 0),
                                                                  covers: [], enemies: [], playerHead: head)
        check(playerBulletPassesPlayer == nil, "a bullet leaving the muzzle never hits the player's own head")

        let enemyHitsHead = ProjectileRules.firstImpact(owner: .enemy, from: SIMD3(0, 0, 0), to: SIMD3(1, 0, 0),
                                                       covers: [], enemies: [], playerHead: head)
        check(enemyHitsHead?.impact == .player, "an enemy bullet reaching the head hits the player")

        let blocked = ProjectileRules.firstImpact(owner: .player, from: SIMD3(0, 0, 0), to: SIMD3(1, 0, 0),
                                                 covers: [cover], enemies: [enemy], playerHead: nil)
        check(blocked?.impact == .cover, "cover in front of an enemy blocks the player's bullet")

        let unblocked = ProjectileRules.firstImpact(owner: .player, from: SIMD3(0, 0, 0), to: SIMD3(1, 0, 0),
                                                   covers: [], enemies: [enemy], playerHead: nil)
        check(unblocked?.impact == .enemy(7), "without cover the same bullet hits the enemy")

        var projectile = ProjectileState(position: SIMD3(0, 0, 0), velocity: SIMD3(30, 0, 0), owner: .player, lifetime: 1)
        let swept = projectile.step(gameDt: fixed)
        check(abs(swept.to.x - 0.25) < 1e-4 && swept.from.x == 0, "a projectile moves velocity times game time per step")
        check(!projectile.expired, "a projectile lives for its game lifetime")

        // MARK: Melee

        var melee = MeleeGate()
        check(melee.allows(key: 1, handSpeed: 1.0, at: 1.0), "the first touch hits")
        check(!melee.allows(key: 1, handSpeed: 1.0, at: 1.2), "a second touch inside the cooldown does not hit again")
        check(melee.allows(key: 1, handSpeed: 1.0, at: 1.36), "the same enemy can be hit again after the cooldown")
        check(melee.allows(key: 2, handSpeed: 1.0, at: 1.2), "the other hand has its own cooldown")
        check(!melee.allows(key: 3, handSpeed: 6.0, at: 2.0), "a tracking jump cannot hit")
        check(!melee.allows(key: 3, handSpeed: .nan, at: 2.0), "a NaN speed cannot hit")

        // MARK: Waves

        var director = WaveDirector()
        var alive = 0
        var spawned = [0, 0, 0]
        var killAt: [Double] = []
        var victory = false
        var t = 0.0
        for _ in 0..<(120 * 120) {
            t += fixed
            let due = killAt.filter { $0 <= t }.count
            alive -= due
            killAt.removeAll { $0 <= t }
            switch director.tick(gameDt: fixed, alive: alive) {
            case let .spawn(wave):
                spawned[wave] += 1
                alive += 1
                killAt.append(t + 0.4)
            case .victory:
                victory = true
            default:
                break
            }
            if victory { break }
        }
        check(spawned == [3, 5, 7] && victory, "three waves of 3, 5 and 7 enemies end in victory")

        var waitingDirector = WaveDirector()
        var enemiesLeft = 0
        for _ in 0..<(120 * 4) {
            if case .spawn = waitingDirector.tick(gameDt: fixed, alive: enemiesLeft) { enemiesLeft += 1 }
        }
        check(enemiesLeft == 3 && waitingDirector.wave == 0, "the first wave does not advance while its enemies are alive")

        // MARK: Health and score

        var health = PlayerHealth()
        check(!health.takeHit() && !health.takeHit(), "the first two hits do not defeat the player")
        check(health.takeHit() && health.isDefeated && health.remaining == 0, "the third hit defeats the player")
        check(health.takeHit() && health.hits == TimeMotionTuning.playerHits, "further hits do not overflow the health")

        var score = TimeMotionScore()
        score.addKill(); score.addKill(); score.addWaveCleared(); score.addVictory()
        check(score.points == 2 * 100 + 250 + 500, "kills, waves and victory add their points")

        let suite = "timeMotion.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        check(TimeMotionBestScore.load(defaults: defaults) == 0, "a new install starts with no best score")
        check(TimeMotionBestScore.record(300, defaults: defaults), "the first score becomes the record")
        check(!TimeMotionBestScore.record(200, defaults: defaults), "a lower score does not replace the record")
        check(TimeMotionBestScore.record(400, defaults: defaults) && TimeMotionBestScore.load(defaults: defaults) == 400,
              "a higher score replaces the record")
        defaults.removePersistentDomain(forName: suite)

        // Camera samples repeated at 60/120 Hz must not change measured hand speed.
        var headMotion = TimeMotionHeadMotion()
        let identity = SIMD4<Float>(0,0,0,1)
        headMotion.update(position:.zero,rotation:identity,timestamp:0,now:0,ready:true)
        headMotion.update(position:SIMD3(0.025,0,0),rotation:identity,timestamp:0.05,now:0.05,ready:true)
        check(headMotion.safe && abs(headMotion.speed-1.2)<0.001,"translation alone produces head activity")
        for i in 1...5 {
            headMotion.update(position:SIMD3(0.025,0,0),rotation:identity,timestamp:0.05,now:0.05+Double(i)*0.008,ready:true)
            check(abs(headMotion.speed-1.2)<0.001,"repeated display frames preserve the captured head speed")
        }
        headMotion.update(position:SIMD3(3,0,0),rotation:identity,timestamp:0.1,now:0.1,ready:true)
        check(!headMotion.safe && headMotion.speed == 0,"relocalisation jump stops game time")
        headMotion.update(position:SIMD3(3,0,0),rotation:identity,timestamp:0.1,now:0.11,ready:true)
        check(!headMotion.safe,"repeated unsafe camera frame cannot resume the game")
        headMotion.update(position:SIMD3(3,0,0),rotation:identity,timestamp:0.15,now:0.15,ready:true)
        check(headMotion.safe && headMotion.speed == 0,"fresh stable frame recovers with no phantom movement")
        headMotion.update(position:SIMD3(3,0,0),rotation:identity,timestamp:0.15,now:0.5,ready:true)
        check(!headMotion.safe,"stale camera pose cannot continue the fight")
        var handMotion = TimeMotionHandMotion()
        handMotion.update(.zero,timestamp:0,generation:1,now:0)
        check(!handMotion.safe,"first hand sample establishes a baseline without a throw")
        handMotion.update(SIMD3(0.03,0,0),timestamp:0.05,generation:1,now:0.05)
        let measured = handMotion.velocity
        for i in 1...5 {
            handMotion.update(SIMD3(0.03,0,0),timestamp:0.05,generation:1,now:0.05+Double(i)*0.008)
            check(handMotion.velocity == measured,"repeated render frames do not decay the camera-sample velocity")
        }
        handMotion.update(SIMD3(0.04,0,0),timestamp:0.10,generation:2,now:0.10)
        check(!handMotion.safe && handMotion.velocity == .zero,"generation change clears velocity")
        handMotion.update(SIMD3(2,0,0),timestamp:0.15,generation:2,now:0.15)
        check(!handMotion.safe && handMotion.velocity == .zero,"tracking jump cannot become a punch or throw")
        handMotion.update(SIMD3(2,0,0),timestamp:0.15,generation:2,now:0.4)
        check(handMotion.position == nil && !handMotion.safe,"stale hand cannot keep firing")
        var throwing = TimeMotionThrow()
        throwing.observe(SIMD3(2,0,0),at:1,safe:true)
        throwing.observe(SIMD3(0.1,0,0),at:1.05,safe:true)
        check(throwing.release(at:1.1).x == 2,"release preserves a recent deliberate swing")
        check(throwing.release(at:1.4) == .zero,"old swing cannot throw later")
        throwing.observe(SIMD3(2,0,0),at:2,safe:true)
        throwing.observe(.zero,at:2.01,safe:false)
        check(throwing.release(at:2.02) == .zero,"tracking loss clears a pending throw")
        let rotated = BoxObstacle(lo:SIMD3(-1,-1,-0.1),hi:SIMD3(1,1,0.1),
            axisX:SIMD3(0.7071068,0,0.7071068),axisZ:SIMD3(-0.7071068,0,0.7071068))
        check(TimeMotionGeometry.hitBox(from:SIMD3(-0.6,0,0.6),to:SIMD3(-0.6,0,0.5),box:rotated) == nil,
              "empty corner of a rotated cover's bounding box does not block a bullet")
        check(TimeMotionGeometry.hitBox(from:SIMD3(0,0,1),to:SIMD3(0,0,-1),box:rotated) != nil,
              "actual rotated cover surface blocks a bullet")
        check(TimeMotionGeometry.segmentBox(from:SIMD3(.nan,0,0),to:.zero,min:SIMD3(repeating:-1),max:SIMD3(repeating:1)) == nil,
              "non-finite geometry cannot produce a phantom hit")
        func shotsAt(_ fps:Int)->Int {
            var clock=FixedStepClock(),fire=FireScheduler(),shots=0
            for _ in 0..<(fps*10) {
                for _ in 0..<clock.advance(realDt:1/Double(fps),scale:0.7) {
                    if fire.advance(gameDt:TimeMotionTuning.fixedStep,firing:true) {shots += 1}
                }
            }
            return shots
        }
        check(shotsAt(30)==shotsAt(60) && shotsAt(60)==shotsAt(120),"auto-fire timing is equal at 30, 60 and 120 display FPS")
        print("PASS: \(count) time-motion checks")
    }
}
