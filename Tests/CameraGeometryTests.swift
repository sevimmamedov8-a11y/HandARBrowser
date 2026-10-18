import Foundation

@main struct CameraGeometryTests {
    static var checks=0
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        checks+=1;precondition(ok(),message)
    }
    static func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
        abs(a.x-b.x)<1e-10 && abs(a.y-b.y)<1e-10
    }
    static func main() {
        // A deliberately off-centre principal point catches incorrect 180-degree
        // flips, which a centred camera model would silently hide.
        for mode in [CameraMode.ultraWide,.worldTracking] {
            let p=CameraProjection(width:1280,height:720,fx:430,fy:435,cx:618,cy:351,rayScale:mode.rayScale)!
            for flipped in [false,true] {
                let map=p.mapping(left:-0.4,right:0.5,bottom:-0.32,top:0.38,flipped:flipped)
                for x in [0.0,0.25,0.5,0.75,1] {
                    for y in [0.0,0.25,0.5,0.75,1] {
                        let screen=SIMD2(x,y), raw=map.offset+map.scale*screen
                        let expected=SIMD2(-0.4+x*0.9,0.38-y*0.7)*(flipped ? -1.0 : 1)
                        check(near(p.tangent(rawUV:raw),expected),"camera sampling and hand ray must aim at the same pixel")
                        let vision=SIMD2(flipped ? 1-raw.x : raw.x,flipped ? raw.y : 1-raw.y)
                        let handRaw=CameraProjection.rawUV(vision:vision,landscapeLeft:flipped)
                        check(near(handRaw,raw)&&near(p.tangent(rawUV:handRaw),expected),"Vision and mask UVs remain aligned in both landscapes")
                    }
                }
            }
            check(near(p.rawUV(tangent:SIMD2(0,0)),SIMD2(618.0/1280,351.0/720)),"optical centre stays fixed at either zoom")
        }
        let one=CameraProjection(width:1280,height:720,fx:500,fy:500,cx:640,cy:360)!
        let half=CameraProjection(width:1280,height:720,fx:500,fy:500,cx:640,cy:360,rayScale:0.5)!
        let uv=SIMD2<Double>(0.75,0.25)
        check(near(half.tangent(rawUV:uv),one.tangent(rawUV:uv)*0.5),"0.5x view halves apparent hand displacement")
        let target=SIMD2<Double>(0.2,0.1)
        check(near(half.rawUV(tangent:target)-SIMD2(0.5,0.5),(one.rawUV(tangent:target)-SIMD2(0.5,0.5))*2),"0.5x samples twice the angular span, with the same UI projection")
        check(CameraProjection(width:0,height:720,fx:500,fy:500,cx:640,cy:360)==nil,"zero-size image rejected")
        check(CameraProjection(width:1280,height:720,fx:0,fy:500,cx:640,cy:360)==nil,"invalid focal length rejected")
        check(CameraProjection(width:1280,height:720,fx:500,fy:500,cx:.nan,cy:360)==nil,"NaN calibration rejected")
        check(CameraProjection(width:1280,height:720,fx:500,fy:500,cx:640,cy:360,rayScale:0)==nil,"invalid zoom rejected")

        let suite="HandARCameraTests-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let calibration=Data([1,2,3,4]);defaults.set(calibration,forKey:"handar.vr.profile.v2")
        check(CameraMode.load(ultraWideAvailable:true,defaults:defaults) == .ultraWide,"new installation defaults to requested 0.5x")
        check(CameraMode.load(ultraWideAvailable:false,defaults:defaults) == .worldTracking,"missing hardware has a usable AR fallback")
        CameraMode.worldTracking.save(defaults:defaults)
        check(CameraMode.load(ultraWideAvailable:true,defaults:defaults) == .worldTracking,"AR selection persists")
        CameraMode.ultraWide.save(defaults:defaults)
        check(CameraMode.load(ultraWideAvailable:true,defaults:defaults) == .ultraWide,"wide selection persists")
        check(defaults.data(forKey:"handar.vr.profile.v2")==calibration,"camera switching cannot reset headset calibration")
        defaults.set("unknown-future-mode",forKey:CameraMode.storageKey)
        check(CameraMode.load(ultraWideAvailable:true,defaults:defaults) == .ultraWide,"unknown saved mode has a safe default")

        var run=CameraRunState()
        check(!run.accepts(mode:.ultraWide,timestamp:1),"stopped camera cannot publish")
        check(!run.acceptsHand(timestamp:1),"stopped camera cannot deliver cached hand input")
        let first=run.begin(.ultraWide,at:10)
        check(run.isCurrent(first,mode:.ultraWide),"current start may finish")
        check(!run.accepts(mode:.worldTracking,timestamp:11),"AR frames cannot enter the wide stream")
        check(!run.accepts(mode:.ultraWide,timestamp:9),"pre-restart frames are rejected")
        check(!run.acceptsHand(timestamp:9)&&run.acceptsHand(timestamp:10.1),"hand callbacks must belong to the new camera run")
        check(run.accepts(mode:.ultraWide,timestamp:10.1),"current wide frame accepted")
        run.stop()
        check(!run.isCurrent(first,mode:.ultraWide) && !run.accepts(mode:.ultraWide,timestamp:11),"exit cancels late startup and frames")
        let second=run.begin(.worldTracking,at:12)
        check(!run.isCurrent(first,mode:.ultraWide)&&run.isCurrent(second,mode:.worldTracking),"mode switch cannot finish an old start")
        check(!run.accepts(mode:.ultraWide,timestamp:13),"old wide stream cannot enter AR")
        check(run.accepts(mode:.worldTracking,timestamp:12.1),"current AR stream accepted")
        check(!run.accepts(mode:.worldTracking,timestamp:.nan),"invalid frame clock rejected")

        let right=CameraOrientationMath.rawCameraBasis(referenceToDevice:[SIMD3(0,0,1),SIMD3(-1,0,0),SIMD3(0,-1,0)])!
        check(right == [SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1)],"upright landscape-right pose has right-handed Y-up camera axes")
        let left=CameraOrientationMath.rawCameraBasis(referenceToDevice:[SIMD3(0,0,-1),SIMD3(1,0,0),SIMD3(0,-1,0)])!
        check(left == [SIMD3(-1,0,0),SIMD3(0,-1,0),SIMD3(0,0,1)],"landscape-left raw sensor rotates 180 degrees without reversing forward")
        // Physical device axes: camera right = -device Y, up = device X.
        // Check gravity with tilted, orthonormal motion matrices as well as upright.
        for angle in [0.0,0.2,0.8,1.5,2.6] {
            let c=cos(angle),s=sin(angle)
            let rows=[SIMD3(c,0,s),SIMD3(0,1,0),SIMD3(-s,0,c)]
            let basis=CameraOrientationMath.rawCameraBasis(referenceToDevice:rows)!
            let deviceGravity=SIMD3(-rows[0].z,-rows[1].z,-rows[2].z)
            let sensorGravity=SIMD3(-deviceGravity.y,deviceGravity.x,deviceGravity.z)
            let gravity=basis[0]*sensorGravity.x+basis[1]*sensorGravity.y+basis[2]*sensorGravity.z
            check(abs(gravity.x)<1e-10 && abs(gravity.y+1)<1e-10 && abs(gravity.z)<1e-10,"sensor gravity always points down in world, including a tilted phone")
        }
        check(CameraOrientationMath.rawCameraBasis(referenceToDevice:[])==nil,"missing motion matrix rejected")
        check(CameraOrientationMath.rawCameraBasis(referenceToDevice:[SIMD3(.nan,0,0),SIMD3(0,1,0),SIMD3(0,0,1)])==nil,"nonfinite motion matrix rejected")
        check(abs(CameraOrientationMath.initialHeading(basis:right))<1e-10,"initial upright camera looks forward")
        check(abs(CameraOrientationMath.initialHeading(basis:[SIMD3(0,0,-1),SIMD3(0,1,0),SIMD3(1,0,0)]) + .pi/2)<1e-10,"initial yaw recentres heading without changing gravity")
        check(CameraOrientationMath.initialHeading(basis:[SIMD3(1,0,0),SIMD3(0,0,1),SIMD3(0,-1,0)]).isFinite,"flat phone can start video before insertion into headset")
        print("PASS: \(checks) camera projection, landscape alignment, modes, lifecycle and orientation checks")
    }
}
