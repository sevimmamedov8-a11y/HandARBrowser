// Pure, time-based gesture rules. No Vision, UIKit or device dependencies.
enum TrackedHand: Int, Hashable { case left, right }

enum PinchTransition { case none, pressed, released, cancelled }

struct StablePinchGesture {
    struct Configuration {
        var closeRatio = 0.25
        var openRatio = 0.42
        var pressSeconds = 0.045
        var releaseSeconds = 0.060
        var rearmSeconds = 0.080
        var maximumSampleGap = 0.200
    }
    private enum Phase { case blocked, ready, closing, down, opening }
    let configuration: Configuration
    private var phase: Phase = .blocked
    private var candidateSince: Double?
    private var lastTimestamp: Double?
    private(set) var isDown = false
    private(set) var isOpenConfirmed = false
    private(set) var generation: UInt64 = 0

    var isEngaged: Bool {
        switch phase {
        case .closing, .down, .opening: return true
        case .blocked, .ready: return false
        }
    }

    init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    mutating func cancel() {
        generation &+= 1
        phase = .blocked
        candidateSince = nil
        lastTimestamp = nil
        isDown = false
        isOpenConfirmed = false
    }

    @discardableResult
    mutating func update(ratio: Double?, confident: Bool, grabbing: Bool = false, at time: Double) -> PinchTransition {
        guard time.isFinite, confident, !grabbing, let ratio, ratio.isFinite, ratio >= 0 else {
            cancel()
            return .cancelled
        }
        if let last = lastTimestamp {
            if time < last || time - last > configuration.maximumSampleGap {
                cancel()
                lastTimestamp = time
                if ratio >= configuration.openRatio { candidateSince = time }
                return .cancelled
            }
            if time == last { return .none }
        }
        lastTimestamp = time
        switch phase {
        case .blocked:
            guard ratio >= configuration.openRatio else { candidateSince = nil; return .none }
            if candidateSince == nil { candidateSince = time }
            if time - candidateSince! + 0.000001 >= configuration.rearmSeconds {
                phase = .ready
                candidateSince = nil
                isOpenConfirmed = true
            }
        case .ready:
            if ratio >= configuration.openRatio { isOpenConfirmed = true }
            if ratio <= configuration.closeRatio {
                phase = .closing
                candidateSince = time
                isOpenConfirmed = false
            }
        case .closing:
            if ratio > configuration.closeRatio {
                phase = .ready
                candidateSince = nil
                isOpenConfirmed = ratio >= configuration.openRatio
            } else if time - (candidateSince ?? time) + 0.000001 >= configuration.pressSeconds {
                phase = .down
                candidateSince = nil
                isDown = true
                return .pressed
            }
        case .down:
            if ratio >= configuration.openRatio {
                phase = .opening
                candidateSince = time
            }
        case .opening:
            if ratio < configuration.openRatio {
                phase = .down
                candidateSince = nil
            } else if time - (candidateSince ?? time) + 0.000001 >= configuration.releaseSeconds {
                phase = .ready
                candidateSince = nil
                isDown = false
                isOpenConfirmed = true
                return .released
            }
        }
        return .none
    }
}

struct StableFistGesture {
    private(set) var isClosed = false
    private var candidate: Bool?
    private var since: Double?
    private var lastTimestamp: Double?

    mutating func reset() { self = StableFistGesture() }

    mutating func update(curled: Int, known: Int, at time: Double) -> Bool {
        if let last = lastTimestamp, time < last || time-last > 0.2 { reset() }
        lastTimestamp = time
        guard time.isFinite, known >= 3 else { reset(); return false }
        let proposed: Bool?
        if curled >= 3 { proposed = true }
        else if curled <= 1 { proposed = false }
        else { proposed = nil }
        guard let proposed else { candidate = nil; since = nil; return isClosed }
        if proposed == isClosed { candidate = nil; since = nil; return isClosed }
        if candidate != proposed { candidate = proposed; since = time }
        if time-(since ?? time)+0.000001 >= (proposed ? 0.070 : 0.050) {
            isClosed = proposed
            candidate = nil
            since = nil
        }
        return isClosed
    }
}

// Bending the index to touch the thumb is not evidence of a panel grab.
enum HandGestureIntent {
    static func allowsFist(indexCurled: Bool?, curled: Int, known: Int,
                           pinchRatio: Double?, pinchEngaged: Bool, indexFoldedIntoPalm: Bool = false) -> Bool {
        guard indexCurled == true, known >= 3, curled >= 3 else { return false }
        // A fully folded fist remains usable even if the thumb rests on the index.
        if known == 4, curled == 4, indexFoldedIntoPalm { return true }
        guard !pinchEngaged else { return false }
        if let pinchRatio { return pinchRatio >= StablePinchGesture.Configuration().openRatio }
        return true // Occluded tips may still form a reliably observed fist.
    }
}

// Keep the pre-pinch aim while the fingers bend. Actual palm translation still
// moves the pointer, so scrolling and dragging do not require fingertip motion.
struct PinchAimStabilizer {
    private var previousIndex: SIMD2<Double>?
    private var previousPalm: SIMD2<Double>?
    private var origin: SIMD2<Double>?
    private var palmOrigin: SIMD2<Double>?

    mutating func reset() { self = PinchAimStabilizer() }

    mutating func update(index: SIMD2<Double>, palm: SIMD2<Double>, engaged: Bool,
                         released: Bool = false) -> SIMD2<Double> {
        defer { previousIndex = index; previousPalm = palm }
        if engaged || released {
            if origin == nil {
                origin = previousIndex ?? index
                palmOrigin = previousPalm ?? palm
            }
            let point = origin! + (palm - palmOrigin!)
            if released { origin = nil; palmOrigin = nil }
            return point
        }
        origin = nil
        palmOrigin = nil
        return index
    }
}

struct HandPinchMeasurement {
    let ratio: Double
    let palmSpan: Double
}

enum HandPinchGeometry {
    static func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let delta = a-b
        return (delta.x*delta.x+delta.y*delta.y).squareRoot()
    }
    // Points are oriented image pixels, not square-normalized Vision coordinates.
    static func measure(thumb: SIMD2<Double>, index: SIMD2<Double>, wrist: SIMD2<Double>,
                        indexBase: SIMD2<Double>, middleBase: SIMD2<Double>,
                        littleBase: SIMD2<Double>? = nil) -> HandPinchMeasurement? {
        let points = [thumb,index,wrist,indexBase,middleBase] + (littleBase.map { [$0] } ?? [])
        guard points.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { return nil }
        var spans = [distance(wrist,indexBase),distance(wrist,middleBase)]
        if let littleBase { spans.append(distance(indexBase,littleBase)) }
        spans.sort()
        let palm = spans.count == 2 ? (spans[0]+spans[1])*0.5 : spans[1]
        guard palm >= 18 else { return nil }
        return HandPinchMeasurement(ratio: distance(thumb,index)/palm, palmSpan: palm)
    }
}

struct HandRoutingState {
    let hand: TrackedHand
    let generation: UInt64
    let down: Bool
    let openConfirmed: Bool
}

struct HandRoutingDecision {
    let hand: TrackedHand?
    let cancel: Bool
    let changedHand: Bool
    let down: Bool
    let began: Bool
}

struct HandInputOwnership {
    private(set) var hand: TrackedHand?
    private var generation: UInt64?
    private var previousDown = false
    private var blocked = true

    mutating func reset() { self = HandInputOwnership() }

    mutating func select(left: HandRoutingState?, right: HandRoutingState?) -> HandRoutingDecision {
        let selected = (hand == .left ? left : (hand == .right ? right : nil)) ?? right ?? left
        guard let selected else {
            let hadHand = hand != nil
            reset()
            return HandRoutingDecision(hand:nil,cancel:hadHand,changedHand:hadHand,down:false,began:false)
        }
        let changedHand = hand != selected.hand
        let changed = changedHand || generation != selected.generation
        if changed {
            previousDown = false
            blocked = selected.down || !selected.openConfirmed
        }
        hand = selected.hand
        generation = selected.generation
        if !selected.down && selected.openConfirmed { blocked = false }
        let down = !blocked && selected.down
        let began = down && !previousDown
        previousDown = down
        return HandRoutingDecision(hand:hand,cancel:changed,changedHand:changedHand,down:down,began:began)
    }

    mutating func suppressUntilOpen() { blocked = true; previousDown = false }
}

// Native controls commit only after a complete press/release on the same target.
struct ReleaseClickGate<Target: Equatable> {
    private var held = false
    private var candidate: Target?

    mutating func cancel() { held = false; candidate = nil }

    mutating func update(target: Target?, down: Bool, allowBegin: Bool) -> Target? {
        let began = down && !held
        let ended = !down && held
        held = down
        if began { candidate = allowBegin ? target : nil }
        if down && candidate != target { candidate = nil }
        guard ended else { return nil }
        let result = candidate == target ? candidate : nil
        candidate = nil
        return result
    }
}
