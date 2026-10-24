import Foundation

enum GraffitiMode { case room, home }

enum GraffitiRoomLayout {
    static let span: Float = 12
    static let floorY: Float = -1.52
    static let ceilingY: Float = 3.68
    static var wallHeight: Float { ceilingY - floorY }
    static var wallCenterY: Float { (ceilingY + floorY) * 0.5 }
    static let maximumPaintDistance: Float = 19
    static var benchZ: Float { span * 0.5 - 0.75 }
}

struct GraffitiPreferences: Codable, Equatable {
    var paintEnabled = true
    var grabbing = true
    var density = 1
    var hardEdge = false
    var brightness = 1
    var grid = true
    var animation = true
    var flow: Double { [0.55, 1, 1.6][max(0, min(2, density))] }
    var light: CGFloat { [0.55, 0.80, 1][max(0, min(2, brightness))] }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "graffiti.preferences.v97"),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              (0...2).contains(value.density), (0...2).contains(value.brightness) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "graffiti.preferences.v97") } }
}

/// Each hand owns its own latch. Loss cannot become a release/regrab gesture.
struct GraffitiGrabGate {
    enum Event: Equatable { case none, began(Int), released(Int), cancelled(Int) }
    private(set) var held: Int?
    private(set) var suppressPainting = false
    private var candidate: Int?
    private var since: Double?
    private var openSince: Double?
    private var paintResetSince: Double?
    private var last: Double?
    private(set) var releaseProgress = 0.0

    mutating func cancel() -> Event {
        let old = held
        if held != nil { suppressPainting = true }
        held = nil; candidate = nil; since = nil; openSince = nil
        releaseProgress = 0; paintResetSince = nil; last = nil
        return old.map(Event.cancelled) ?? .none
    }

    mutating func update(target: Int?, fist: Bool, open: Bool, reliable: Bool, blocked: Bool, at time: Double) -> Event {
        guard reliable, time.isFinite else { return cancel() }
        if let last, time < last || time-last > 0.2 { return cancel() }
        last = time
        if let held {
            if open && !fist {
                if openSince == nil { openSince = time }
                releaseProgress = min(1, (time-(openSince ?? time))/2)
                if time-(openSince ?? time) >= 2-0.000001 {
                    self.held = nil; candidate = nil; since = nil; releaseProgress = 0
                    return .released(held)
                }
            } else {
                openSince = nil; releaseProgress = 0
            }
            return .none
        }
        if suppressPainting {
            if target == nil && !open {
                if paintResetSince == nil { paintResetSince = time }
                if time-(paintResetSince ?? time) >= 0.10-0.000001 { suppressPainting = false }
            } else { paintResetSince = nil }
        }
        if !fist {
            candidate = nil; since = nil
            openSince = nil
            return .none
        }
        openSince = nil
        guard !blocked, let target else { candidate = nil; since = nil; return .none }
        if candidate != target { candidate = target; since = time }
        guard time-(since ?? time) >= 0.10-0.000001 else { return .none }
        held = target; suppressPainting = true
        return .began(target)
    }
}

enum GraffitiPropGeometry {
    static func rayDistance(origin: SIMD3<Float>, direction: SIMD3<Float>, center: SIMD3<Float>, radius: Float) -> Float? {
        let delta = center-origin
        let t = delta.x*direction.x + delta.y*direction.y + delta.z*direction.z
        guard t.isFinite, t > 0.12, t < GraffitiRoomLayout.maximumPaintDistance else { return nil }
        let offset = delta-direction*t
        let allowance = radius + min(0.18, t*0.035)
        return offset.x*offset.x+offset.y*offset.y+offset.z*offset.z <= allowance*allowance ? t : nil
    }
    static func restingPosition(_ position: SIMD3<Float>, halfSize: SIMD3<Float>) -> SIMD3<Float> {
        let half = GraffitiRoomLayout.span*0.5
        let x = min(half-halfSize.x-0.08, max(-half+halfSize.x+0.08, position.x))
        let z = min(half-halfSize.z-0.08, max(-half+halfSize.z+0.08, position.z))
        let onBench = x-halfSize.x >= -2.90 && x+halfSize.x <= -0.40 &&
            abs(z-GraffitiRoomLayout.benchZ)+halfSize.z <= 0.325 && position.y >= GraffitiRoomLayout.floorY+0.9
        let support = GraffitiRoomLayout.floorY + (onBench ? 0.93 : 0.028)
        return SIMD3(x, support+halfSize.y, z)
    }
}

enum GraffitiRoomMood: Int, CaseIterable {
    case neon, sunset, mint
    var title: String { ["Неон", "Закат", "Мята"][rawValue] }
    var next: Self { Self(rawValue: (rawValue + 1) % Self.allCases.count)! }
}

/// A briefly stable open palm paints automatically. Every interruption starts
/// a new stroke; neither another hand nor a missing frame can bridge it.
struct GraffitiSprayGate {
    private(set) var owner: TrackedHand?
    private(set) var canVisible = false
    private var last: Double?
    private var openSince: Double?

    mutating func cancel() {
        canVisible = false; openSince = nil; last = nil
    }

    mutating func update(hand: TrackedHand?, open: Bool,
                         reliable: Bool, blocked: Bool, at time: Double) -> Bool {
        guard reliable, let hand, time.isFinite else { cancel(); return false }
        if let last, time < last || time - last > 0.2 { cancel() }
        if let owner, owner != hand { cancel() }
        owner = hand; last = time
        guard open, !blocked else { canVisible = false; openSince = nil; return false }
        if openSince == nil { openSince = time }
        canVisible = time - (openSince ?? time) + 0.000001 >= 0.08
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
