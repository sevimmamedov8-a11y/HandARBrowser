import Foundation

enum GraffitiMode { case room, home }

/// Only a fresh, owned fist may paint. Reacquisition, menus and tracking loss
/// need a visible open palm before starting another stroke.
struct GraffitiSprayGate {
    private(set) var owner: TrackedHand?
    private(set) var canVisible = false
    private(set) var armed = true
    private var last: Double?
    private var openSince: Double?

    mutating func cancel() {
        canVisible = false; armed = false; openSince = nil; last = nil
    }

    mutating func update(hand: TrackedHand?, fist: Bool, open: Bool,
                         reliable: Bool, blocked: Bool, at time: Double) -> Bool {
        guard reliable, let hand, time.isFinite else { cancel(); return false }
        if let last, time < last || time - last > 0.2 { cancel() }
        if let owner, owner != hand { cancel() }
        owner = hand; last = time; canVisible = fist
        if blocked { armed = false; openSince = nil; return false }
        if open && !fist {
            if openSince == nil { openSince = time }
            if time - (openSince ?? time) >= 0.08 { armed = true }
        } else { openSince = nil }
        return fist && armed
    }
}

/// Fixed spray cadence and distance interpolation keep strokes continuous
/// without making a long line across a tracking gap or between walls.
struct GraffitiStrokeSampler {
    private var lastPoint: SIMD2<Double>?
    private var lastTime: Double?
    mutating func reset() { self = Self() }

    mutating func points(to point: SIMD2<Double>, radius: Double, at time: Double) -> [SIMD2<Double>] {
        guard point.x.isFinite, point.y.isFinite, time.isFinite,
              radius.isFinite, radius > 0 else { reset(); return [] }
        if let lastTime, time >= lastTime, time - lastTime < 1.0 / 30 { return [] }
        var result = [point]
        if let previous = lastPoint, let lastTime, time >= lastTime, time - lastTime <= 0.2 {
            let delta = point - previous
            let length = sqrt(delta.x * delta.x + delta.y * delta.y)
            if length <= 0.5 {
                let steps = min(48, max(1, Int(ceil(length / max(0.004, radius * 0.35)))))
                result = (1...steps).map { previous + delta * (Double($0) / Double(steps)) }
            }
        }
        lastPoint = point; lastTime = time
        return result
    }
}

enum GraffitiGeometry {
    /// A paint plane uses local XY, with its image origin at the top left.
    static func uv(point: SIMD2<Double>, size: SIMD2<Double>) -> SIMD2<Double>? {
        guard size.x > 0, size.y > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let uv = SIMD2(point.x / size.x + 0.5, 0.5 - point.y / size.y)
        return (0...1).contains(uv.x) && (0...1).contains(uv.y) ? uv : nil
    }
    static func canDistance(palmFraction: Double, verticalTangent: Double) -> Float {
        guard palmFraction.isFinite, verticalTangent.isFinite,
              palmFraction > 0.001, verticalTangent > 0 else { return 0.5 }
        return Float(min(0.85, max(0.25, 0.08 / (2 * palmFraction * verticalTangent))))
    }
}
