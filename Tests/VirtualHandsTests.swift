import Foundation

@main struct VirtualHandsTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
        var points = [SIMD3<Float>?](repeating: nil, count: 21)
        points[0] = SIMD3(0, 0, -0.5)
        let xs: [Float] = [0.045, 0.03, 0, -0.025, -0.045]
        for finger in 0..<5 {
            for joint in 0..<4 { points[1+finger*4+joint] = SIMD3(xs[finger], 0.08+Float(joint)*0.025, -0.5) }
        }
        let pose = VirtualHandPose(points: points, camera: .zero)!
        check(abs(pose.length-0.08) < 0.0001, "palm keeps observed scale")
        check(VirtualHandPose.dot(pose.normal, -pose.center) > 0, "normal faces camera")
        check(abs(VirtualHandPose.dot(pose.across, pose.along)) < 0.0001, "orthogonal palm basis")
        check(VirtualHandPose.length(VirtualHandPose.cross(pose.across, pose.along)-pose.normal) < 0.0001, "right handed basis")
        for f in 0..<5 { for j in 0..<3 { check(pose.segment(finger: f, joint: j) != nil, "all visible phalanges") } }
        for index in [0, 5, 9, 17] {
            var partial = points; partial[index] = nil
            check(VirtualHandPose(points: partial, camera: .zero) == nil, "missing palm anchor hides glove")
        }
        for index in [6, 7, 8] {
            var partial = points; partial[index] = nil
            let p = VirtualHandPose(points: partial, camera: .zero)!
            for joint in 0..<3 where 5+joint == index || 6+joint == index {
                check(p.segment(finger: 1, joint: joint) == nil, "no bridge over a missing finger joint")
            }
            check(p.segment(finger: 2, joint: 2) != nil, "other fingers stay independent")
        }
        var invalid = points; invalid[7] = SIMD3(.nan, 0, 0)
        check(VirtualHandPose(points: invalid, camera: .zero)?.segment(finger: 1, joint: 1) == nil, "invalid point cannot deform a finger")
        invalid = points; invalid[8] = SIMD3(10, 10, 10)
        check(VirtualHandPose(points: invalid, camera: .zero)?.segment(finger: 1, joint: 2) == nil, "outlier cannot create a long spike")
        invalid = points; invalid[17] = points[5]
        check(VirtualHandPose(points: invalid, camera: .zero) == nil, "degenerate palm hidden")
        invalid = points; invalid[5] = SIMD3(0, 0.04, -0.5); invalid[17] = SIMD3(0, 0.12, -0.5)
        check(VirtualHandPose(points: invalid, camera: .zero) == nil, "edge-on unstable basis hidden")
        for scale: Float in [0.01, 10] {
            check(VirtualHandPose(points: points.map { $0.map { $0*scale } }, camera: .zero) == nil, "unreasonable glove size hidden")
        }
        for timestamp in [10.0, 9.9] { check(VirtualHandPose.fresh(timestamp, at: 10), "current samples accepted") }
        for timestamp in [9.87, 10.01, .nan, .infinity] { check(!VirtualHandPose.fresh(timestamp, at: 10), "stale and invalid samples rejected") }
        check(!VirtualHandPose.fresh(10, at: .nan), "invalid clock rejected")
        for hand in [false, true] {
            for distance: Float in [0.25, 0.5, 0.85] {
                for rotation: Float in [0, .pi/2, .pi] {
                    let right = SIMD3(cos(rotation), sin(rotation), 0), up = SIMD3(-sin(rotation), cos(rotation), 0)
                    let offset = VirtualHandPose.canOffset(distance: distance, left: hand, right: right, up: up)
                    let horizontal = VirtualHandPose.dot(offset, right)
                    check((horizontal < 0) == hand && abs(horizontal) > 0.06, "can stays on correct side away from paint ray")
                    check(VirtualHandPose.dot(offset, up) < 0 && abs(offset.z) < 0.0001, "can is lower in camera axes, not world axes")
                }
            }
        }
        var fingers: [[SIMD2<Double>?]] = []
        for f in 0..<5 {
            var chain: [SIMD2<Double>?] = []
            for j in 0..<4 { chain.append(SIMD2<Double>(Double(160-f*20), Double(120-j*20))) }
            fingers.append(chain)
        }
        let cutout = HandSilhouette.make(wrist: SIMD2(120, 200), fingers: fingers)!
        let removal = cutout.removalEnvelope()
        check(cutout.palm.count == removal.palm.count && cutout.segments.count == removal.segments.count, "removal stays local with same topology")
        for (a, b) in zip(cutout.segments, removal.segments) {
            check(a.start == b.start && a.end == b.end, "removal preserves finger positions")
            check(b.startRadius > a.startRadius && b.endRadius > a.endRadius, "removal covers edges outside conservative cutout")
            check(b.startRadius < 20 && b.endRadius < 20, "mask does not expand to unrelated room pixels")
        }
        print("PASS: \(count) virtual hand geometry, freshness, can clearance and removal envelope checks")
    }
}
