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
