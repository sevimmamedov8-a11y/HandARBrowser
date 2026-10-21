import Foundation

enum CameraMode: String {
    case ultraWide = "ultra-wide"
    case worldTracking = "world-tracking"
    static let storageKey = "handar.camera.mode.v1"

    static func load(ultraWideAvailable: Bool, defaults: UserDefaults = .standard) -> CameraMode {
        let requested = defaults.string(forKey:storageKey).flatMap(CameraMode.init(rawValue:)) ?? .ultraWide
        return requested == .ultraWide && !ultraWideAvailable ? .worldTracking : requested
    }
    func save(defaults: UserDefaults = .standard) { defaults.set(rawValue,forKey:Self.storageKey) }
    // Physical ultra-wide lens stays at 1.0 (its native 0.5x lens). The view
    // shows wider angles too, rather than cropping them back to the old AR view.
    var rayScale: Double { self == .ultraWide ? 0.5 : 1 }
}

// One model shared by passthrough sampling and hand hit testing. Coordinates
// are unrotated camera pixels / UVs, with the image origin at top left.
struct CameraProjection {
    let width: Double, height: Double
    let fx: Double, fy: Double, cx: Double, cy: Double
    let rayScale: Double

    init?(width: Double, height: Double, fx: Double, fy: Double, cx: Double, cy: Double, rayScale: Double = 1) {
        guard [width,height,fx,fy,cx,cy,rayScale].allSatisfy(\.isFinite),
              width > 0, height > 0, fx > 0, fy > 0, rayScale > 0 else { return nil }
        self.width=width;self.height=height;self.fx=fx;self.fy=fy
        self.cx=cx;self.cy=cy;self.rayScale=rayScale
    }
    /// Aspect fill for the complete eye frustum. Use this same projection for
    /// hand rays, otherwise widening the passthrough would shift hit testing.
    func covering(x: Double, y: Double) -> CameraProjection {
        let horizontal = min(cx, width-cx) / fx
        let vertical = min(cy, height-cy) / fy
        guard horizontal > 0, vertical > 0, x.isFinite, y.isFinite else { return self }
        let scale = max(rayScale, max(abs(x)/horizontal, abs(y)/vertical) * 1.001)
        return CameraProjection(width: width, height: height, fx: fx, fy: fy,
                                cx: cx, cy: cy, rayScale: scale) ?? self
    }
    func tangent(rawUV uv: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2((uv.x*width-cx)/fx,(cy-uv.y*height)/fy)*rayScale
    }
    func rawUV(tangent: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2((cx+fx*tangent.x/rayScale)/width,(cy-fy*tangent.y/rayScale)/height)
    }
    static func rawUV(vision: SIMD2<Double>, landscapeLeft: Bool) -> SIMD2<Double> {
        SIMD2(landscapeLeft ? 1-vision.x : vision.x,landscapeLeft ? vision.y : 1-vision.y)
    }
    func mapping(left: Double, right: Double, bottom: Double, top: Double,
                 flipped: Bool) -> (scale: SIMD2<Double>, offset: SIMD2<Double>) {
        var scale = SIMD2(fx*(right-left)/width,fy*(top-bottom)/height)/rayScale
        var offset = rawUV(tangent:SIMD2(left,top))
        if flipped { scale = -scale; offset = rawUV(tangent:SIMD2(-left,-top)) }
        return (scale,offset)
    }
}

struct CameraRunState {
    private(set) var mode: CameraMode?
    private(set) var generation: UInt64 = 0
    private var startedAt = Double.infinity
    mutating func begin(_ mode: CameraMode, at time: Double) -> UInt64 {
        generation &+= 1;self.mode=mode;startedAt=time;return generation
    }
    mutating func stop() { generation &+= 1;mode=nil;startedAt = .infinity }
    func isCurrent(_ token: UInt64, mode: CameraMode) -> Bool { generation == token && self.mode == mode }
    func accepts(mode: CameraMode, timestamp: Double) -> Bool {
        self.mode == mode && timestamp.isFinite && timestamp >= startedAt
    }
    func acceptsHand(timestamp: Double) -> Bool {
        mode != nil && timestamp.isFinite && timestamp >= startedAt
    }
}

enum CameraOrientationMath {
    // Core Motion: reference Z is vertical; the attitude maps reference to device.
    // Convert its inverse to Y-up SceneKit and the sensor's landscape-right axes.
    static func rawCameraBasis(referenceToDevice rows: [SIMD3<Double>]) -> [SIMD3<Double>]? {
        guard rows.count == 3, rows.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        func world(_ p: SIMD3<Double>) -> SIMD3<Double> { SIMD3(p.x,p.z,-p.y) }
        // Sensor +X runs from the front camera toward the home-button end
        // (-device Y); sensor +Y is device +X. UI landscapeRight is the
        // opposite name to UIDeviceOrientation.landscapeLeft.
        return [world(-rows[1]),world(rows[0]),world(rows[2])]
    }
    static func initialHeading(basis: [SIMD3<Double>]) -> Double {
        let forward = -basis[2]
        if hypot(forward.x,forward.z)>0.1 { return atan2(forward.x,-forward.z) }
        // A phone lying flat still needs live camera frames during insertion into
        // the headset; its image-right axis provides the initial horizontal yaw.
        let right=basis[0]
        return atan2(right.z,right.x)
    }
}

/// Extra source coverage for radial correction over a rectangular viewport.
enum LensCoverage {
    static func overscan(center: SIMD2<Double>, aspect: Double, k1: Double, k2: Double, chroma: Double) -> Double {
        let x = max(abs(center.x), abs(1-center.x)) * aspect
        let y = max(abs(center.y), abs(1-center.y))
        let radius2 = x*x+y*y
        func factor(_ r: Double) -> Double { 1+k1*r+k2*r*r }
        var maximum = max(1, factor(radius2))
        if k2 < 0 {
            let peak = -k1/(2*k2)
            if peak > 0 && peak < radius2 { maximum = max(maximum, factor(peak)) }
        }
        return max(1, maximum * (1+abs(chroma))) * 1.00001
    }
}

enum SpatialWindowSizing {
    static let storageKey = "handar.window.width.v1"
    static let presets: [Float] = [1.9, 2.9, 3.8]
    static func nextWidth(after width: Float) -> Float {
        presets.first { $0 > width + 0.1 } ?? presets[0]
    }
    static func restoredWidth(defaults: UserDefaults, fallback: Float) -> Float {
        guard let number = defaults.object(forKey: storageKey) as? NSNumber else { return fallback }
        let width = number.floatValue
        return width.isFinite ? min(3.8, max(0.72, width)) : fallback
    }
}

/// A single central-camera image, placed under two physical lenses. All values
/// are in display coordinates: source UV is shared; only output alignment varies.
enum MonoViewGeometry {
    static func lensCenter(eye: Int, screenWidth: Double, screenHeight: Double,
                           separation: Double, horizontal: Double = 0,
                           vertical: Double = 0, rightVertical: Double = 0) -> SIMD2<Double> {
        let width = max(screenWidth, 1), height = max(screenHeight, 1)
        let x = (eye == 0 ? 1-separation/width : separation/width) + 2*horizontal/width
        return SIMD2(min(0.9,max(0.1,x)), min(0.9,max(0.1,0.5-(vertical+(eye == 0 ? 0:rightVertical))/height)))
    }

    static func renderScale(centers: [SIMD2<Double>], aspect: Double, k1: Double, k2: Double, chroma: Double) -> Double {
        centers.map { center in
            let extent = 2*max(max(abs(center.x),abs(1-center.x)),max(abs(center.y),abs(1-center.y)))
            return extent * LensCoverage.overscan(center:center,aspect:aspect,k1:k1,k2:k2,chroma:chroma)
        }.max() ?? 1
    }

    /// Inverse of the compositor's green-channel lookup, before source overscan.
    static func displayUV(source: SIMD2<Double>, center: SIMD2<Double>, aspect: Double,
                          k1: Double, k2: Double) -> SIMD2<Double>? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        let p=(source-SIMD2(0.5,0.5))*SIMD2(aspect,1)
        let length=hypot(p.x,p.y)
        var radius=length
        for _ in 0..<16 where length > 1e-9 {
            let r2=radius*radius
            let derivative=1+3*k1*r2+5*k2*r2*r2
            guard derivative>1e-8 else { return nil }
            radius=max(0,radius-(radius*(1+k1*r2+k2*r2*r2)-length)/derivative)
        }
        let result=center+p*(length>1e-9 ? radius/length:1)/SIMD2(aspect,1)
        return result.x.isFinite && result.y.isFinite ? result:nil
    }

    static func replicaShift(left: SIMD2<Double>, right: SIMD2<Double>, width: Double, height: Double) -> SIMD2<Double> {
        SIMD2(width*0.5*(1+right.x-left.x),height*(right.y-left.y))
    }

    // One crop is shared by both copies so neither can bleed into the other eye.
    // The camera behind the floating window still fills the entire display.
    static func sourceViewport(width: Double, height: Double, shift: SIMD2<Double>) -> (origin: SIMD2<Double>, size: SIMD2<Double>) {
        let half=width*0.5
        let origin=SIMD2(max(0,half-shift.x),max(0,-shift.y))
        let end=SIMD2(min(half,width-shift.x),min(height,height-shift.y))
        return (origin,SIMD2(max(0,end.x-origin.x),max(0,end.y-origin.y)))
    }
}

/// Clip a control's projected outline to one eye, preventing opposite-eye holes.
enum CinemaControlMask {
    static func clipped(_ polygon: [SIMD2<Double>], minX: Double, maxX: Double, maxY: Double) -> [SIMD2<Double>] {
        guard polygon.count >= 3, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              minX.isFinite, maxX.isFinite, maxY.isFinite, maxX > minX, maxY > 0 else { return [] }
        var result = polygon
        let bounds: [(Int, Double, Bool)] = [(0, minX, true), (0, maxX, false), (1, 0, true), (1, maxY, false)]
        for (axis, edge, lower) in bounds {
            guard !result.isEmpty else { return [] }
            let input = result
            result = []
            for i in input.indices {
                let a = input[i], b = input[(i + 1) % input.count]
                let insideA = lower ? a[axis] >= edge : a[axis] <= edge
                let insideB = lower ? b[axis] >= edge : b[axis] <= edge
                if insideA { result.append(a) }
                if insideA != insideB {
                    let t = (edge - a[axis]) / (b[axis] - a[axis])
                    result.append(a + (b - a) * t)
                }
            }
        }
        return result.count >= 3 ? result : []
    }
}
