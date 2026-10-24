import Foundation
import simd

// Pure rules for the time-motion shooter: no SceneKit, UIKit or ARKit.
// Covered by Tests/TimeMotionTests.swift. Game scene code lives in TimeMotionGame.swift.

enum TimeMotionTuning {
    /// Game physics run in fixed 120 Hz steps, so the display frame rate does not change the game.
    static let fixedStep: Double = 1.0 / 120.0
    /// A long stall advances the game by at most this much real time.
    static let maxRealStep: Double = 0.1
    static let maxStepsPerFrame = 12
    static let minimumScale: Double = 0.05
    /// Head angular speed (rad/s) and hand speed (m/s) below these values are sensor jitter.
    static let headNoise: Double = 0.25
    static let handNoise: Double = 0.08
    /// Faster than these is a tracking jump. The sample is ignored and the speed is held.
    static let headGlitch: Double = 6.0
    static let handGlitch: Double = 4.0
    /// Speeds that reach full game speed.
    static let headFull: Double = 1.2
    static let handFull: Double = 0.9
    /// Missing tracking for this long (real seconds) pauses the game.
    static let trackingLossPause: Double = 0.2
    static let fireInterval: Double = 0.28
    static let fireRearm: Double = 0.12
    static let meleeCooldown: Double = 0.35
    static let meleeMaxHandSpeed: Double = 4.0
    static let introSeconds: Double = 1.5
    static let spawnGapSeconds: Double = 0.6
    static let breatherSeconds: Double = 2.5
    static let playerHits = 3
    /// Radius of the player's head for enemy bullets, metres.
    static let playerHeadRadius: Float = 0.18
}

/// One reading per camera frame. Only `.motion` changes game speed.
enum MotionSample: Equatable {
    /// No fresh head pose or hand. The game pauses after `trackingLossPause`.
    case lost
    /// A fresh but implausible reading. The current speed is kept and the game does not pause.
    case glitch
    /// Head angular speed (rad/s) and the faster hand's speed (m/s).
    case motion(head: Double, hand: Double)
}

/// Maps the player's motion to game speed. Moving makes time run at full speed,
/// keeping still makes it crawl, and losing tracking pauses it.
struct TimeScaleController {
    private(set) var scale: Double = TimeMotionTuning.minimumScale
    private(set) var isPaused = false
    private var lostFor: Double = 0
    private var target: Double = TimeMotionTuning.minimumScale

    mutating func reset() { self = TimeScaleController() }

    static func targetScale(head: Double, hand: Double) -> Double {
        let headSpeed = head < TimeMotionTuning.headNoise ? 0 : head
        let handSpeed = hand < TimeMotionTuning.handNoise ? 0 : hand
        let activity = min(1, max(headSpeed / TimeMotionTuning.headFull, handSpeed / TimeMotionTuning.handFull))
        let eased = activity * activity * (3 - 2 * activity)
        return TimeMotionTuning.minimumScale + (1 - TimeMotionTuning.minimumScale) * eased
    }

    mutating func update(_ sample: MotionSample, realDt: Double) {
        guard realDt.isFinite, realDt >= 0 else { return }
        let dt = min(realDt, TimeMotionTuning.maxRealStep)
        switch sample {
        case .lost:
            lostFor += dt
        case .glitch:
            lostFor = 0
        case let .motion(head, hand):
            lostFor = 0
            if head.isFinite, hand.isFinite, head >= 0, hand >= 0,
               head <= TimeMotionTuning.headGlitch, hand <= TimeMotionTuning.handGlitch {
                target = Self.targetScale(head: head, hand: hand)
            }
        }
        if lostFor >= TimeMotionTuning.trackingLossPause {
            if !isPaused {
                isPaused = true
                scale = 0
            }
            return
        }
        if isPaused {
            // Resume from the slowest speed, never from the last value. Nothing jumps.
            isPaused = false
            scale = TimeMotionTuning.minimumScale
        }
        let tau = target > scale ? 0.12 : 0.35
        scale += (target - scale) * (1 - exp(-dt / tau))
    }
}

/// Converts real frame time into fixed game steps. Frame rate does not change the result.
struct FixedStepClock {
    private(set) var gameTime: Double = 0
    private var accumulator: Double = 0

    mutating func reset() { self = FixedStepClock() }

    /// Returns how many fixed game steps to run this frame. A scale of 0 stops time.
    mutating func advance(realDt: Double, scale: Double) -> Int {
        guard realDt.isFinite, realDt >= 0, scale.isFinite else { return 0 }
        accumulator += min(realDt, TimeMotionTuning.maxRealStep) * min(1, max(0, scale))
        var steps = 0
        while accumulator >= TimeMotionTuning.fixedStep, steps < TimeMotionTuning.maxStepsPerFrame {
            accumulator -= TimeMotionTuning.fixedStep
            steps += 1
        }
        // Drop any backlog instead of running a catch-up burst after a stall.
        if steps == TimeMotionTuning.maxStepsPerFrame { accumulator = 0 }
        gameTime += Double(steps) * TimeMotionTuning.fixedStep
        return steps
    }
}

/// Automatic fire on game time. A shot never builds a queue: releasing the gun or losing
/// the hand re-arms it with a short delay, and at most one shot comes out per step.
struct FireScheduler {
    private(set) var cooldown = TimeMotionTuning.fireRearm

    /// Call once per fixed game step. Returns true when a shot should leave the barrel now.
    mutating func advance(gameDt: Double, firing: Bool) -> Bool {
        guard firing else {
            cooldown = TimeMotionTuning.fireRearm
            return false
        }
        guard gameDt.isFinite, gameDt >= 0 else { return false }
        cooldown -= gameDt
        guard cooldown <= 0 else { return false }
        cooldown = TimeMotionTuning.fireInterval
        return true
    }

    mutating func rearm() { cooldown = TimeMotionTuning.fireRearm }
}

enum TimeMotionGeometry {
    /// First hit parameter t in 0...1 along the segment a→b, or nil. Sweeping the whole
    /// step is what stops fast bullets from passing through a target between frames.
    static func segmentSphere(from a: SIMD3<Float>, to b: SIMD3<Float>,
                              center: SIMD3<Float>, radius: Float) -> Float? {
        let d = b - a
        let f = a - center
        let qa = simd_dot(d, d)
        let qb = simd_dot(f, d)
        let qc = simd_dot(f, f) - radius * radius
        guard qa.isFinite, qb.isFinite, qc.isFinite else { return nil }
        if qc <= 0 { return 0 }
        if qa < 1e-12 { return nil }
        let discriminant = qb * qb - qa * qc
        guard discriminant >= 0 else { return nil }
        let t = (-qb - discriminant.squareRoot()) / qa
        return (0...1).contains(t) ? max(0, t) : nil
    }

    /// Slab test for an axis-aligned box. Returns the first entry parameter in 0...1.
    static func segmentBox(from a: SIMD3<Float>, to b: SIMD3<Float>,
                           min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Float? {
        var entry: Float = 0
        var exit: Float = 1
        for axis in 0..<3 {
            let origin = a[axis]
            let delta = b[axis] - origin
            if abs(delta) < 1e-9 {
                if origin < lo[axis] || origin > hi[axis] { return nil }
                continue
            }
            var near = (lo[axis] - origin) / delta
            var far = (hi[axis] - origin) / delta
            if near > far { swap(&near, &far) }
            entry = max(entry, near)
            exit = min(exit, far)
            if entry > exit { return nil }
        }
        return entry
    }
}

enum ProjectileOwner: Equatable { case player, enemy }

/// A bullet that moves in game time and is checked along its swept path each step.
struct ProjectileState: Equatable {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    let owner: ProjectileOwner
    private(set) var age: Double = 0
    let lifetime: Double

    init(position: SIMD3<Float>, velocity: SIMD3<Float>, owner: ProjectileOwner, lifetime: Double) {
        self.position = position
        self.velocity = velocity
        self.owner = owner
        self.lifetime = lifetime
    }

    var expired: Bool { age >= lifetime }

    /// Moves one fixed game step and returns the swept segment to test.
    mutating func step(gameDt: Double) -> (from: SIMD3<Float>, to: SIMD3<Float>) {
        let from = position
        position += velocity * Float(gameDt)
        age += gameDt
        return (from, position)
    }
}

struct BoxObstacle: Equatable {
    let lo: SIMD3<Float>
    let hi: SIMD3<Float>
}

struct SphereTarget: Equatable {
    let id: Int
    let center: SIMD3<Float>
    let radius: Float
}

enum ProjectileImpact: Equatable {
    case cover
    case enemy(Int)
    case player
}

enum ProjectileRules {
    /// The earliest contact along one swept step. Cover blocks both sides. The player's
    /// bullets pass the player's own head and only hit enemies. Enemy bullets only hit the head.
    static func firstImpact(owner: ProjectileOwner, from a: SIMD3<Float>, to b: SIMD3<Float>,
                            covers: [BoxObstacle], enemies: [SphereTarget],
                            playerHead: SphereTarget?) -> (impact: ProjectileImpact, t: Float)? {
        var best: (impact: ProjectileImpact, t: Float)?
        func consider(_ impact: ProjectileImpact, _ t: Float?) {
            guard let t else { return }
            if best == nil || t < best!.t { best = (impact, t) }
        }
        for box in covers {
            consider(.cover, TimeMotionGeometry.segmentBox(from: a, to: b, min: box.lo, max: box.hi))
        }
        switch owner {
        case .player:
            for target in enemies {
                consider(.enemy(target.id),
                         TimeMotionGeometry.segmentSphere(from: a, to: b, center: target.center, radius: target.radius))
            }
        case .enemy:
            if let head = playerHead {
                consider(.player,
                         TimeMotionGeometry.segmentSphere(from: a, to: b, center: head.center, radius: head.radius))
            }
        }
        return best
    }
}

/// Melee contact with an enemy. Each enemy and hand pair can hit once per cooldown.
/// A fast hand is a tracking jump, so it cannot hit at all.
struct MeleeGate {
    private var last: [Int: Double] = [:]

    mutating func reset() { last.removeAll() }

    mutating func allows(key: Int, handSpeed: Double, at time: Double) -> Bool {
        guard handSpeed.isFinite, handSpeed >= 0,
              handSpeed <= TimeMotionTuning.meleeMaxHandSpeed, time.isFinite else { return false }
        if let previous = last[key], time >= previous, time - previous < TimeMotionTuning.meleeCooldown {
            return false
        }
        last[key] = time
        return true
    }
}

struct PlayerHealth: Equatable {
    private(set) var hits = 0

    var isDefeated: Bool { hits >= TimeMotionTuning.playerHits }
    var remaining: Int { max(0, TimeMotionTuning.playerHits - hits) }

    /// Returns true when this hit defeats the player.
    mutating func takeHit() -> Bool {
        guard !isDefeated else { return true }
        hits += 1
        return isDefeated
    }
}

struct TimeMotionScore: Equatable {
    static let killPoints = 100
    static let waveBonus = 250
    static let victoryBonus = 500

    private(set) var points = 0

    mutating func addKill() { points += Self.killPoints }
    mutating func addWaveCleared() { points += Self.waveBonus }
    mutating func addVictory() { points += Self.victoryBonus }
}

/// Three waves of 3, 5 and 7 enemies. Waves advance on game time.
struct WaveDirector {
    enum Event: Equatable {
        case none
        case spawn(wave: Int)
        case waveCleared(wave: Int)
        case victory
    }

    enum Phase: Equatable { case intro, spawning, fighting, breather, finished }

    static let waveSizes = [3, 5, 7]

    private(set) var wave = 0
    private(set) var phase: Phase = .intro
    private(set) var toSpawn = 0
    private var timer = TimeMotionTuning.introSeconds

    /// `alive` is the number of enemies currently on the field.
    mutating func tick(gameDt: Double, alive: Int) -> Event {
        guard gameDt.isFinite, gameDt >= 0, phase != .finished else { return .none }
        switch phase {
        case .intro:
            timer -= gameDt
            if timer <= 0 {
                phase = .spawning
                toSpawn = Self.waveSizes[wave]
                timer = 0
            }
            return .none
        case .spawning:
            timer -= gameDt
            guard timer <= 0 else { return .none }
            toSpawn -= 1
            timer = TimeMotionTuning.spawnGapSeconds
            if toSpawn == 0 { phase = .fighting }
            return .spawn(wave: wave)
        case .fighting:
            guard alive <= 0 else { return .none }
            phase = .breather
            timer = TimeMotionTuning.breatherSeconds
            return .waveCleared(wave: wave)
        case .breather:
            timer -= gameDt
            guard timer <= 0 else { return .none }
            if wave + 1 >= Self.waveSizes.count {
                phase = .finished
                return .victory
            }
            wave += 1
            phase = .intro
            timer = TimeMotionTuning.introSeconds
            return .none
        case .finished:
            return .none
        }
    }
}

/// Best score is stored locally only. Tests pass their own UserDefaults suite.
enum TimeMotionBestScore {
    static let key = "timeMotion.bestScore.v1"

    static func load(defaults: UserDefaults = .standard) -> Int {
        max(0, defaults.integer(forKey: key))
    }

    /// Saves the score only when it beats the stored best. Returns true for a new record.
    @discardableResult
    static func record(_ score: Int, defaults: UserDefaults = .standard) -> Bool {
        guard score > load(defaults: defaults) else { return false }
        defaults.set(score, forKey: key)
        return true
    }
}
