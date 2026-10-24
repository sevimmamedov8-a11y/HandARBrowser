import Foundation
import simd

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
        let beforeGlitch = glitch.scale
        for _ in 0..<60 { glitch.update(.motion(head: 20, hand: 0), realDt: dt60) }
        check(abs(glitch.scale - beforeGlitch) < 1e-6 && !glitch.isPaused, "a tracking jump holds the current speed and does not pause")
        for _ in 0..<60 { glitch.update(.glitch, realDt: dt60) }
        check(!glitch.isPaused && glitch.scale > 0.9, "an unreliable frame does not pause or slow the game")

        var lost = TimeScaleController()
        for _ in 0..<120 { lost.update(.motion(head: 2.0, hand: 0.6), realDt: dt60) }
        for _ in 0..<6 { lost.update(.lost, realDt: dt60) }
        check(!lost.isPaused, "a short tracking gap of 0.1 s does not pause")
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
        check(simd_length(SIMD3<Float>(1, 0, 0) - SIMD3(0.5, 0, 0)) > 0.05, "endpoints alone would have missed the target")

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

        print("PASS: \(count) time-motion checks")
    }
}
