import Foundation

/// An inferred avatar, not camera-based foot tracking. All coordinates are room-local.
struct GraffitiFootPose {
    let center: SIMD3<Float>
    let forward: SIMD3<Float>
    let previous: SIMD3<Float>
    let velocity: SIMD3<Float>
    var toe: SIMD3<Float> { center + forward * 0.075 }
    var heel: SIMD3<Float> { center - forward * 0.075 }
}

struct GraffitiLegMotion {
    private var lastHead: SIMD3<Float>?
    private var lastTime: Double?
    private var heading = SIMD3<Float>(0,0,-1)
    private var phase: Float = 0
    private var stride: Float = 0
    private var previous: [SIMD3<Float>] = []
    private(set) var continuous = false
    mutating func reset() { self = Self() }
    mutating func update(head: SIMD3<Float>, forward: SIMD3<Float>, time: Double, ready: Bool) -> [GraffitiFootPose] {
        guard ready, time.isFinite, [head.x,head.y,head.z,forward.x,forward.y,forward.z].allSatisfy({ $0.isFinite }) else {
            reset(); return []
        }
        let dt = time - (lastTime ?? time)
        let delta = head - (lastHead ?? head)
        continuous = lastHead != nil && dt > 0 && dt <= 0.2 && GraffitiFlight.length(delta) < 0.45
        let flat = SIMD3(forward.x,0,forward.z), length = GraffitiFlight.length(flat)
        if !continuous { previous = []; stride = 0; phase = 0 }
        // Looking down must not spin the legs around the camera's near-vertical axis.
        if length > 0.25 {
            let direction = flat/length
            let mixed = continuous ? heading + (direction-heading)*min(1,Float(dt)*5) : direction
            if GraffitiFlight.length(mixed) > 0.01 { heading = mixed/GraffitiFlight.length(mixed) }
        }
        if continuous {
            let travel = sqrt(delta.x*delta.x+delta.z*delta.z)
            let speed = min(2,travel/Float(dt))
            phase += travel * 10
            stride += (min(1,speed/0.6)-stride)*min(1,Float(dt)*8)
        }
        let right = SIMD3(-heading.z,0,heading.x)
        let base = SIMD3(head.x,GraffitiRoomLayout.floorY+0.075,head.z)
        var feet: [GraffitiFootPose] = []
        for index in 0..<2 {
            let side: Float = index == 0 ? -1 : 1
            let swing = sin(phase + (index == 0 ? 0 : .pi)) * stride
            var center = base + right*(side*0.145) + heading*(0.08+swing*0.16)
            center.y += max(0,swing)*0.055
            let old = previous.count == 2 ? previous[index] : center
            let velocity = continuous ? GraffitiFlight.capped((center-old)/Float(dt),at:3) : .zero
            feet.append(GraffitiFootPose(center:center,forward:heading,previous:old,velocity:velocity))
        }
        previous = feet.map(\.center); lastHead = head; lastTime = time
        return feet
    }
}

/// Contact must first be separated, including after relocalisation or a hand release.
struct GraffitiFootContact {
    private var armed = [false,false]
    mutating func reset() { armed = [false,false] }
    mutating func hit(feet: [GraffitiFootPose], ball: SIMD3<Float>, velocity: SIMD3<Float>, radius: Float,
                      enabled: Bool) -> (position: SIMD3<Float>, velocity: SIMD3<Float>)? {
        guard enabled, feet.count == 2 else { reset(); return nil }
        let reach = radius + 0.085
        for index in 0..<2 {
            let foot = feet[index]
            var nearest = foot.toe, currentEnd = foot.toe, distance = Float.infinity
            // Sweep both capsule ends to avoid passing through the ball between frames.
            for end in [foot.toe,foot.center,foot.heel] {
                let start = end + foot.previous-foot.center, segment = end-start
                let squared = segment.x*segment.x+segment.y*segment.y+segment.z*segment.z
                let offset = ball-start
                let dot = offset.x*segment.x+offset.y*segment.y+offset.z*segment.z
                let t = squared > 0.000001 ? min(1,max(0,dot/squared)) : 1
                let point = start+segment*t, d = GraffitiFlight.length(ball-point)
                if d < distance { distance = d; nearest = point; currentEnd = end }
            }
            if distance > reach+0.035 { armed[index] = true }
            guard armed[index], distance < reach else { continue }
            // A ball between both shoes must escape instead of ping-ponging every frame.
            armed = [false,false]
            var normal = SIMD3(ball.x-nearest.x,0,ball.z-nearest.z)
            let n = GraffitiFlight.length(normal)
            normal = n > 0.005 ? normal/n : foot.forward
            let relative = foot.velocity-velocity
            let approach = max(0,relative.x*normal.x+relative.z*normal.z)
            let power = min(4.8,1.1+approach*1.3)
            let impulse = normal*power + SIMD3(0,min(1.5,0.45+approach*0.22),0)
            var position = ball
            // Clear the present shoe as well as the swept contact; physics clamps room bounds.
            let separation = position-currentEnd
            let projected = separation.x*normal.x+separation.z*normal.z
            position += normal*max(0,reach+0.006-projected)
            return (position,GraffitiFlight.capped(impulse,at:5))
        }
        return nil
    }
}

struct GraffitiCollider {
    let center: SIMD3<Float>
    let half: SIMD3<Float>
}

/// Lightweight bounded box motion in studio coordinates. Fixed substeps avoid
/// tunnelling through the tabletop and keep pause/resume from causing a jump.
struct GraffitiFlight {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var angles: SIMD3<Float>
    var spin: SIMD3<Float>
    var resting = false
    private var contactTime: Float = 0
    private var restAngles: SIMD3<Float>?
    init(position: SIMD3<Float>, velocity: SIMD3<Float>, angles: SIMD3<Float>, spin: SIMD3<Float>) {
        self.position = position; self.velocity = velocity; self.angles = angles; self.spin = spin
    }
    static func releaseSpin(velocity: SIMD3<Float>, hand: TrackedHand) -> SIMD3<Float> {
        // A small off-centre release also tumbles a gently dropped object.
        let side: Float = hand == .left ? -1 : 1
        return capped(SIMD3(velocity.z*1.8+1.1, velocity.x*0.5+side*0.35, -velocity.x*1.8+side*0.85), at: 8)
    }
    static func length(_ v: SIMD3<Float>) -> Float { sqrt(v.x*v.x+v.y*v.y+v.z*v.z) }
    static func capped(_ v: SIMD3<Float>, at limit: Float) -> SIMD3<Float> {
        let n = length(v)
        return n.isFinite ? v * min(1, limit/max(0.0001,n)) : .zero
    }
    static func extent(half: SIMD3<Float>, angles: SIMD3<Float>) -> SIMD3<Float> {
        let cx = cos(angles.x), sx = sin(angles.x), cy = cos(angles.y), sy = sin(angles.y)
        let cz = cos(angles.z), sz = sin(angles.z)
        let x = SIMD3(cy*cz, cy*sz, -sy)
        let y = SIMD3(sx*sy*cz-cx*sz, sx*sy*sz+cx*cz, sx*cy)
        let z = SIMD3(cx*sy*cz+sx*sz, cx*sy*sz-sx*cz, cx*cy)
        return SIMD3(abs(x.x),abs(x.y),abs(x.z))*half.x +
            SIMD3(abs(y.x),abs(y.y),abs(y.z))*half.y + SIMD3(abs(z.x),abs(z.y),abs(z.z))*half.z
    }
    private static func flatAngles(half: SIMD3<Float>, near angles: SIMD3<Float>) -> SIMD3<Float> {
        let quarter = Float.pi/2
        var best = angles, score = Float.infinity
        // Choose a nearby low face, not the original upright pose. Preserve
        // yaw when possible; quarter-turn candidates also cover side faces.
        for x in -1...1 { for y in -1...1 { for z in -1...1 {
            let candidate = SIMD3((angles.x/quarter).rounded()+Float(x),
                                 (angles.y/quarter).rounded()+Float(y),
                                 (angles.z/quarter).rounded()+Float(z))*quarter
            let height = extent(half: half, angles: candidate).y
            let cost = height*20 + length(candidate-angles)*0.06
            if cost < score { score = cost; best = candidate }
        } } }
        return best
    }
    mutating func step(_ elapsed: Float, halfSize: SIMD3<Float>, obstacles: [GraffitiCollider], ball: Bool = false) -> Float {
        guard !resting, elapsed.isFinite, elapsed > 0 else { return 0 }
        let duration = min(0.05, elapsed), count = max(1, Int(ceil(duration*120)))
        let dt = duration/Float(count)
        var impact: Float = 0
        for _ in 0..<count {
            velocity.y -= 9.81*dt
            position += velocity*dt; angles += spin*dt
            let half = ball ? halfSize : Self.extent(half: halfSize, angles: angles)
            let limit = GraffitiRoomLayout.span*0.5
            let low = SIMD3(-limit+half.x, GraffitiRoomLayout.floorY+0.028+half.y, -limit+half.z)
            let high = SIMD3(limit-half.x, GraffitiRoomLayout.ceilingY-half.y, limit-half.z)
            var supported = false
            var supportY = low.y-half.y
            let restitution: Float = ball ? 0.68 : 0.25
            var contactImpact: Float = 0
            for axis in 0..<3 {
                if position[axis] < low[axis] {
                    position[axis] = low[axis]
                    if velocity[axis] < 0 { contactImpact = max(contactImpact,-velocity[axis]); velocity[axis] *= -restitution }
                    if axis == 1 { supported = true }
                } else if position[axis] > high[axis] {
                    position[axis] = high[axis]
                    if velocity[axis] > 0 { contactImpact = max(contactImpact,velocity[axis]); velocity[axis] *= -restitution }
                }
            }
            for box in obstacles {
                let delta = position-box.center
                let overlap = half+box.half-SIMD3(abs(delta.x),abs(delta.y),abs(delta.z))
                guard overlap.x > 0, overlap.y > 0, overlap.z > 0 else { continue }
                var axis = 0
                if overlap.y < overlap[axis] { axis = 1 }
                if overlap.z < overlap[axis] { axis = 2 }
                let direction: Float = delta[axis] >= 0 ? 1 : -1
                position[axis] += direction*overlap[axis]
                if velocity[axis]*direction < 0 { contactImpact = max(contactImpact,abs(velocity[axis])); velocity[axis] *= -restitution }
                if axis == 1 && direction > 0 { supported = true; supportY = box.center.y+box.half.y }
            }
            impact = max(impact, contactImpact)
            if supported {
                let friction: Float = ball ? 0.75 : 7
                velocity.x *= max(0,1-friction*dt); velocity.z *= max(0,1-friction*dt)
                if ball {
                    let rolling = SIMD3(velocity.z/max(0.02,halfSize.x), spin.y*0.9, -velocity.x/max(0.02,halfSize.x))
                    spin += (rolling-spin)*min(1,dt*18)
                    if abs(velocity.y) < 0.18 && Self.length(velocity) < 0.08 { resting = true }
                } else {
                    if contactImpact > 0.6 {
                        spin += SIMD3(velocity.z+contactImpact*0.22, 0, -velocity.x+contactImpact*0.17)
                        spin = Self.capped(spin, at: 9)
                    }
                    spin *= max(0,1-5*dt)
                    // Once the bounce ends, gravity tips the body onto a low
                    // face with a damped rotation instead of freezing on an edge.
                    if abs(velocity.y) < 0.3 {
                        contactTime += dt
                        if restAngles == nil { restAngles = Self.flatAngles(half: halfSize, near: angles) }
                        if let target = restAngles {
                            let error = target-angles
                            spin += error*(38*dt); spin *= max(0,1-6*dt)
                            angles += error*min(1,dt*2)
                            let extent = Self.extent(half: halfSize, angles: angles)
                            position.y = supportY+extent.y
                            position.x = min(limit-extent.x,max(-limit+extent.x,position.x))
                            position.z = min(limit-extent.z,max(-limit+extent.z,position.z))
                            if contactTime > 0.25 && Self.length(error) < 0.015 && Self.length(velocity) < 0.15 {
                                angles = target; position.y = supportY+Self.extent(half:halfSize,angles:target).y
                                resting = true
                            }
                        }
                    }
                }
                if resting { velocity = .zero; spin = .zero; break }
            } else {
                contactTime = 0; restAngles = nil
                spin *= max(0,1-0.12*dt)
            }
        }
        return impact
    }
}

/// Twelve curved pentagonal patches over a white sphere; shared triangle mesh.
enum GraffitiFootball {
    static func patches() -> (vertices: [SIMD3<Float>], indices: [Int32]) {
        let phi = Float((1+sqrt(5.0))/2)
        var directions: [SIMD3<Float>] = []
        for a: Float in [-1,1] { for b in [-phi,phi] {
            directions += [SIMD3(0,a,b), SIMD3(a,b,0), SIMD3(b,0,a)]
        } }
        var vertices: [SIMD3<Float>] = [], indices: [Int32] = []
        func unit(_ v: SIMD3<Float>) -> SIMD3<Float> { v/GraffitiFlight.length(v) }
        for direction in directions {
            let n = unit(direction), u = unit(SIMD3(n.z,0,-n.x))
            let v = SIMD3(n.y*u.z-n.z*u.y,n.z*u.x-n.x*u.z,n.x*u.y-n.y*u.x)
            let corners = (0..<5).map { i -> SIMD3<Float> in
                let angle = Float(i)*2*Float.pi/5
                return (u*cos(angle)+v*sin(angle))*0.34
            }
            let base = Int32(vertices.count)
            vertices.append(n*1.006)
            for ring in 1...3 { for edge in 0..<5 { for step in 0..<3 {
                let f = Float(step)/3
                let offset = (corners[edge]*(1-f)+corners[(edge+1)%5]*f)*Float(ring)/3
                vertices.append(unit(n+offset)*1.006)
            } } }
            for i in 0..<15 {
                let next = (i+1)%15
                indices += [base,base+1+Int32(i),base+1+Int32(next)]
                for ring in 0..<2 {
                    let inner = base+1+Int32(ring*15), outer = inner+15
                    indices += [inner+Int32(i),outer+Int32(i),outer+Int32(next),inner+Int32(i),outer+Int32(next),inner+Int32(next)]
                }
            }
        }
        return (vertices,indices)
    }
}
