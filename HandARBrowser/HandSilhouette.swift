// Conservative hand silhouette in camera pixels. Geometry scales with the hand,
// never with the mask texture's dimensions. Missing joints leave a gap.
struct HandSilhouette {
    struct Segment {
        let start: SIMD2<Double>
        let end: SIMD2<Double>
        let startRadius: Double
        let endRadius: Double
    }
    let palm: [SIMD2<Double>]
    let segments: [Segment]

    /// Removal needs a wider envelope than a foreground cutout. This is a local
    /// approximation, not image segmentation; never expand the ordinary mask.
    func removalEnvelope() -> HandSilhouette {
        let center = palm.reduce(SIMD2<Double>.zero, +) / Double(palm.count)
        let length = HandPinchGeometry.distance((palm[0]+palm[5])*0.5, palm[2])
        let margin = length*0.14
        let expanded = palm.map { p -> SIMD2<Double> in
            let delta = p-center, distance = HandPinchGeometry.distance(p, center)
            return distance > 0.5 ? p+delta/distance*margin : p
        }
        let wider = segments.map { s in
            Segment(start: s.start, end: s.end,
                    startRadius: max(s.startRadius*1.65, length*0.085),
                    endRadius: max(s.endRadius*1.65, length*0.065))
        }
        return HandSilhouette(palm: expanded, segments: wider)
    }

    // Fingers are thumb, index, middle, ring, little; each runs base to tip.
    static func make(wrist: SIMD2<Double>?, fingers: [[SIMD2<Double>?]]) -> HandSilhouette? {
        guard fingers.count == 5, fingers.allSatisfy({ $0.count == 4 }),
              let wrist, let index = fingers[1][0], let middle = fingers[2][0],
              let little = fingers[4][0] else { return nil }
        let all = [wrist] + fingers.flatMap { $0.compactMap { $0 } }
        guard all.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let length = HandPinchGeometry.distance(wrist,middle)
        let width = HandPinchGeometry.distance(index,little)
        guard length >= 18, width >= 6 else { return nil }
        let across = (index-little)/width
        // Stay inside the observed knuckle spacing, including side-on hands.
        var radius = min(length*0.10,width*0.14)
        for pair in [(1,2),(2,3),(3,4)] {
            if let a = fingers[pair.0][0], let b = fingers[pair.1][0] {
                radius = min(radius,HandPinchGeometry.distance(a,b)*0.40)
            }
        }
        guard radius > 0.5 else { return nil }
        let palm = [wrist-across*width*0.22, little-across*radius*0.82,
                    middle, index+across*radius, fingers[0][0] ?? wrist+across*width*0.22,
                    wrist+across*width*0.22]
        let taper = [1.0,0.88,0.72,0.52]
        let factors = [1.12,1.0,1.0,0.92,0.78]
        var segments: [Segment] = []
        for finger in 0..<5 {
            for joint in 0..<3 {
                guard let a = fingers[finger][joint], let b = fingers[finger][joint+1],
                      HandPinchGeometry.distance(a,b) > 0.5 else { continue }
                segments.append(Segment(start:a,end:b,
                    startRadius:radius*factors[finger]*taper[joint],
                    endRadius:radius*factors[finger]*taper[joint+1]))
            }
        }
        return HandSilhouette(palm:palm,segments:segments)
    }
}
