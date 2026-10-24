import Foundation

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
    mutating func step(_ elapsed: Float, halfSize: SIMD3<Float>, obstacles: [GraffitiCollider]) -> Float {
        guard !resting, elapsed.isFinite, elapsed > 0 else { return 0 }
        let duration = min(0.05, elapsed), count = max(1, Int(ceil(duration*120)))
        let dt = duration/Float(count)
        var impact: Float = 0
        for _ in 0..<count {
            velocity.y -= 9.81*dt
            position += velocity*dt; angles += spin*dt
            let half = Self.extent(half: halfSize, angles: angles)
            let limit = GraffitiRoomLayout.span*0.5
            let low = SIMD3(-limit+half.x, GraffitiRoomLayout.floorY+0.028+half.y, -limit+half.z)
            let high = SIMD3(limit-half.x, GraffitiRoomLayout.ceilingY-half.y, limit-half.z)
            var supported = false
            for axis in 0..<3 {
                if position[axis] < low[axis] {
                    position[axis] = low[axis]
                    if velocity[axis] < 0 { impact = max(impact,-velocity[axis]); velocity[axis] *= -0.25 }
                    if axis == 1 { supported = true }
                } else if position[axis] > high[axis] {
                    position[axis] = high[axis]
                    if velocity[axis] > 0 { impact = max(impact,velocity[axis]); velocity[axis] *= -0.25 }
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
                if velocity[axis]*direction < 0 { impact = max(impact,abs(velocity[axis])); velocity[axis] *= -0.25 }
                if axis == 1 && direction > 0 { supported = true }
            }
            if supported {
                velocity.x *= max(0,1-9*dt); velocity.z *= max(0,1-9*dt)
                spin *= max(0,1-12*dt)
                if Self.length(velocity) < 0.15 && Self.length(spin) < 0.3 { velocity = .zero; spin = .zero; resting = true }
            }
        }
        return impact
    }
}
