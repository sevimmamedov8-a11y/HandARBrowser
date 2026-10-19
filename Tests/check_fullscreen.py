"""Execute production rectangular-eye coverage and camera/hand alignment math."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
def method(start, end):
    return source[source.index(start):source.index(end, source.index(start))].replace('private func', 'func')

lens = source[source.index('struct EyeFrustum {'):source.index('    static func projection(_ frustum:')]+ '\n}\n'
frustum = method('    private func fullEyeFrustum(', '    private func applyEyeGeometry()')
stubs = r'''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
struct VRProfile {
 var screenWidthMM:Float=147,screenHeightMM:Float=68,eyeToScreenMM:Float=42
 var lensVerticalOffsetMM:Float=0,fovScale:Float=1,k1:Float=0,k2:Float=0,chroma:Float=0
 var screenHorizontalOffsetMM:Float?=nil,rightEyeVerticalOffsetMM:Float?=nil,lensSeparationMM:Float=63
}
final class Harness {
 var profile=VRProfile()
'''
tests = r'''
}
@main struct Tests {
 static func main() {
  var checks=0
  func check(_ ok:Bool,_ message:String) {checks+=1;precondition(ok,message)}
  let h=Harness()
  for aspect in [0.8,1.0,1.2,1.4] {for offset:Float in [-8,0,8] {for k1:Float in [0,0.4,0.8] {for k2:Float in [-0.2,0,0.6] {
   h.profile.lensVerticalOffsetMM=offset;h.profile.k1=k1;h.profile.k2=k2;h.profile.chroma=0.015
   let c=VRLensMath.lensCenterUV(eye:0,profile:h.profile)
   let center=SIMD2(Double(c.x),Double(c.y))
   let factor=Double(VRLensMath.renderScale(profile:h.profile,aspect:Float(aspect)))
   let base=VRLensMath.frustum(eye:0,profile:h.profile),wide=h.fullEyeFrustum(eye:0,aspect:Float(aspect))
   let raw=CameraProjection(width:1280,height:720,fx:530,fy:535,cx:627,cy:355,rayScale:0.5)!
   let camera=raw.covering(x:Double(max(abs(wide.left),abs(wide.right))),y:Double(max(abs(wide.bottom),abs(wide.top))))
   for ix in 0...10 {for iy in 0...10 {
    let uv=SIMD2(Double(ix)/10,Double(iy)/10)
    let p=(uv-center)*SIMD2(aspect,1),r2=p.x*p.x+p.y*p.y
    let f=1+Double(k1)*r2+Double(k2)*r2*r2
    for channel in [-1.0,0,1] {
     let sample=SIMD2<Double>(0.5,0.5)+(uv-center)*f*(1+channel*Double(h.profile.chroma))/factor
     check(sample.x>=(-1e-6) && sample.x<=1.000001 && sample.y>=(-1e-6) && sample.y<=1.000001,"warped texture samples stay within their own eye, including corners")
    }
    let sample=SIMD2<Double>(0.5,0.5)+(uv-center)*f/factor
    let tangent=SIMD2(Double(wide.left)+sample.x*Double(wide.right-wide.left),Double(wide.top)-sample.y*Double(wide.top-wide.bottom))
    let original=SIMD2<Double>(0.5,0.5)+(uv-center)*f
    let expected=SIMD2(Double(base.left)+original.x*Double(base.right-base.left),Double(base.top)-original.y*Double(base.top-base.bottom))
    check(abs(tangent.x-expected.x)<1e-5 && abs(tangent.y-expected.y)<1e-5,"overscan preserves calibrated scene scale and optical center")
    for flipped in [false,true] {
     let mapping=camera.mapping(left:Double(wide.left),right:Double(wide.right),bottom:Double(wide.bottom),top:Double(wide.top),flipped:flipped)
     let rawUV=sample*mapping.scale+mapping.offset
     check(rawUV.x>=0 && rawUV.x<=1 && rawUV.y>=0 && rawUV.y<=1,"camera fills corners in both landscape orientations")
     let ray=camera.tangent(rawUV:rawUV)*(flipped ? -1.0 : 1.0)
     check(abs(ray.x-tangent.x)<1e-6 && abs(ray.y-tangent.y)<1e-6,"hand ray matches the displayed camera pixel within Float frustum precision")
    }
   }}
  }}}}
  print("PASS: \(checks) fullscreen coverage, optical scale, camera/hand alignment checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-fullscreen-') as directory:
    path=Path(directory)/'fullscreen.swift'
    path.write_text(lens+stubs+frustum+tests,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/CameraGeometry.swift',path])
