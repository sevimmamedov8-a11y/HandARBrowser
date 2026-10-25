import Foundation

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
    /// Faster than these is a tracking jump; gameplay pauses until a valid sample.
    static let headGlitch: Double = 6.0
    static let handGlitch: Double = 4.0
    /// Speeds that reach full game speed.
    static let headFull: Double = 1.2
    static let handFull: Double = 0.9
    static let fireInterval: Double = 0.28
    static let fireRearm: Double = 0.12
    static let meleeCooldown: Double = 0.35
    static let meleeMaxHandSpeed: Double = 4.0
    static let introSeconds: Double = 0.15
    static let spawnGapSeconds: Double = 0.6
    static let breatherSeconds: Double = 0.3
    static let playerHits = 3
    /// Radius of the player's head for enemy bullets, metres.
    static let playerHeadRadius: Float = 0.18
}

/// One reading per camera frame. Only `.motion` changes game speed.
enum MotionSample: Equatable {
    /// No reliable camera pose: pause immediately. Missing hands alone do not pause.
    case lost
    /// An implausible camera pose: pause rather than damage the player.
    case glitch
    /// Head angular speed (rad/s) and the faster hand's speed (m/s).
    case motion(head: Double, hand: Double)
}

/// Maps the player's motion to game speed. Moving makes time run at full speed,
/// keeping still makes it crawl, and losing tracking pauses it.
struct TimeScaleController {
    private(set) var scale: Double = TimeMotionTuning.minimumScale
    private(set) var isPaused = false
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
            isPaused = true; scale = 0; target = TimeMotionTuning.minimumScale
            return
        case .glitch:
            isPaused = true; scale = 0; target = TimeMotionTuning.minimumScale
            return
        case let .motion(head, hand):
            if head.isFinite, hand.isFinite, head >= 0, hand >= 0,
               head <= TimeMotionTuning.headGlitch, hand <= TimeMotionTuning.handGlitch {
                target = Self.targetScale(head: head, hand: hand)
            } else { isPaused = true; scale = 0; target = TimeMotionTuning.minimumScale; return }
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
        guard gameDt.isFinite, gameDt > 0 else { return false }
        cooldown -= gameDt
        guard cooldown <= 0 else { return false }
        cooldown = max(0, cooldown + TimeMotionTuning.fireInterval)
        return true
    }

    mutating func rearm() { cooldown = TimeMotionTuning.fireRearm }
}

enum TimeMotionGeometry {
    static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x+a.y*b.y+a.z*b.z }
    static func length(_ a: SIMD3<Float>) -> Float { sqrt(dot(a,a)) }
    /// First hit parameter t in 0...1 along the segment a→b, or nil. Sweeping the whole
    /// step is what stops fast bullets from passing through a target between frames.
    static func segmentSphere(from a: SIMD3<Float>, to b: SIMD3<Float>,
                              center: SIMD3<Float>, radius: Float) -> Float? {
        let d = b - a
        let f = a - center
        let qa = dot(d, d)
        let qb = dot(f, d)
        let qc = dot(f, f) - radius * radius
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
            guard a[axis].isFinite, b[axis].isFinite, lo[axis].isFinite, hi[axis].isFinite, lo[axis] <= hi[axis] else { return nil }
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

    static func hitBox(from a: SIMD3<Float>, to b: SIMD3<Float>, box: BoxObstacle, padding: Float = 0) -> Float? {
        let half = (box.hi-box.lo)*0.5+SIMD3(repeating:padding)
        return segmentBox(from:box.local(a),to:box.local(b),min:-half,max:half)
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
    var axisX = SIMD3<Float>(1,0,0)
    var axisZ = SIMD3<Float>(0,0,1)
    func local(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let delta = point-(lo+hi)*0.5
        return SIMD3(TimeMotionGeometry.dot(delta,axisX),delta.y,TimeMotionGeometry.dot(delta,axisZ))
    }
    func worldVector(_ vector: SIMD3<Float>) -> SIMD3<Float> { axisX*vector.x+SIMD3(0,vector.y,0)+axisZ*vector.z }
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
            consider(.cover, TimeMotionGeometry.hitBox(from:a,to:b,box:box))
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

/// Head activity also uses capture timestamps so 30 Hz tracking on a 60/120 Hz
/// display produces the same activity, including translation while dodging.
struct TimeMotionHeadMotion {
    private var position: SIMD3<Float>?
    private var rotation: SIMD4<Float>?
    private var timestamp: Double?
    private(set) var safe = false
    private(set) var speed = 0.0
    mutating func reset() { self = Self() }
    mutating func update(position point: SIMD3<Float>, rotation quaternion: SIMD4<Float>, timestamp stamp: Double, now: Double, ready: Bool) {
        guard ready, stamp.isFinite, now.isFinite, now >= stamp, now-stamp <= 0.2,
              [point.x,point.y,point.z,quaternion.x,quaternion.y,quaternion.z,quaternion.w].allSatisfy({ $0.isFinite }) else { reset(); return }
        if let previous = timestamp, stamp == previous { return }
        var activity = 0.0, valid = true
        if let previous = timestamp, let old = position, let q = rotation {
            let dt = stamp-previous, travel = Double(TimeMotionGeometry.length(point-old))
            let dot = q.x*quaternion.x+q.y*quaternion.y+q.z*quaternion.z+q.w*quaternion.w
            let angle = Double(2*acos(min(1,abs(dot))))
            valid = dt > 0 && dt <= 0.2 && travel < 0.25 && angle/max(0.00001,dt) < 6
            if valid {
                let translation = travel/dt
                activity = min(5.9,max(angle/dt,translation > 0.035 ? translation*2.4 : 0))
            }
        }
        position = point; rotation = quaternion; timestamp = stamp; speed = activity; safe = valid
    }
}

/// Velocity belongs to camera samples, never repeated render frames. A new
/// tracking generation or implausible jump requires a fresh baseline.
struct TimeMotionHandMotion {
    private(set) var position: SIMD3<Float>?
    private(set) var previous: SIMD3<Float>?
    private(set) var velocity = SIMD3<Float>.zero
    private(set) var safe = false
    private var stamp: Double?
    private var generation: UInt64?
    mutating func reset() { self = Self() }
    mutating func update(_ point: SIMD3<Float>?, timestamp: Double, generation: UInt64?, now: Double) {
        guard let point, let generation, timestamp.isFinite, now.isFinite,
              now >= timestamp, now-timestamp <= 0.18,
              [point.x,point.y,point.z].allSatisfy({ $0.isFinite }) else { reset(); return }
        if self.generation != generation || stamp == nil || timestamp < stamp! || timestamp-stamp! > 0.2 {
            reset(); self.generation = generation; position = point; previous = point; stamp = timestamp; return
        }
        guard timestamp > stamp! else { previous = position; return }
        let dt = Float(timestamp-stamp!), delta = point-position!
        previous = position; position = point; stamp = timestamp
        let speed = TimeMotionGeometry.length(delta)/dt
        guard speed <= 4, TimeMotionGeometry.length(delta) < 0.25 else {
            velocity = .zero; previous = point; safe = false; return
        }
        velocity += (delta/dt-velocity)*(1-exp(-dt/0.055))
        safe = true
    }
}

/// Preserve a recent deliberate swing through the two-second open-palm release.
/// An idle hand or tracking break cannot throw an object using an old velocity.
struct TimeMotionThrow {
    private var peak = SIMD3<Float>.zero
    private var peakTime = -Double.infinity
    mutating func reset() { self = Self() }
    mutating func observe(_ velocity: SIMD3<Float>, at time: Double, safe: Bool) {
        guard safe else { reset(); return }
        if time-peakTime > 0.22 || TimeMotionGeometry.length(velocity) >= TimeMotionGeometry.length(peak) {
            peak = velocity; peakTime = time
        }
    }
    func release(at time: Double) -> SIMD3<Float> {
        guard time >= peakTime, time-peakTime <= 0.22 else { return .zero }
        return peak*min(1,6/max(0.001,TimeMotionGeometry.length(peak)))
    }
}
