import Foundation

enum GraffitiMode { case room, home }

enum GraffitiRoomLayout {
    static let span: Float = 8
    static let floorY: Float = -1.52
    static let ceilingY: Float = 2.68
    static var wallHeight: Float { ceilingY - floorY }
    static var wallCenterY: Float { (ceilingY + floorY) * 0.5 }
    static let maximumPaintDistance: Float = 13
}

/// A deliberate UI toggle enables painting with a fresh, owned open palm.
/// Loss, hand changes and menus disable it until another explicit toggle.
struct GraffitiSprayGate {
    private(set) var owner: TrackedHand?
    private(set) var canVisible = false
    private(set) var isEnabled = false
    private var last: Double?
    private var open = false

    mutating func cancel() {
        canVisible = false; isEnabled = false; open = false; last = nil
    }

    /// Enabling needs a currently visible open palm, including in head-aim mode.
    @discardableResult mutating func toggle(at time: Double) -> Bool {
        if isEnabled { cancel(); return true }
        guard time.isFinite, let last, time >= last, time - last <= 0.2,
              owner != nil, open else { return false }
        isEnabled = true
        return true
    }

    mutating func update(hand: TrackedHand?, open: Bool,
                         reliable: Bool, blocked: Bool, at time: Double) -> Bool {
        guard reliable, let hand, time.isFinite else { cancel(); return false }
        if let last, time < last || time - last > 0.2 { cancel() }
        if let owner, owner != hand { cancel() }
        owner = hand; last = time; self.open = open
        // Hovering a control pauses the stroke without undoing its enable action.
        canVisible = isEnabled && open && !blocked
        return canVisible
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
