"""Execute production rectangular-eye math, live layout and pointer hit tests."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
def method(start, end):
    return source[source.index(start):source.index(end, source.index(start))].replace('private func', 'func')

lens = source[source.index('struct EyeFrustum {'):source.index('    static func projection(_ frustum:')]+ '\n}\n'
frustum = method('    private func fullEyeFrustum(', '    private func applyEyeGeometry()')
layout = method('    private func layoutDirectVideoStage()', '    private func navigateLiveBrowser(')
target = method('    private func directVideoTarget(', '    private func setDirectVideoNotice(')
pointers = method('    private func updateFlatWebPointers(', '    private func updateDirectVideoInput(')
stubs = r'''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
let CATransform3DIdentity = 0
final class Layer { var transform=0;var anchorPoint=CGPoint.zero;var cornerRadius:CGFloat=0;var masksToBounds=false }
class View {
 var frame=CGRect.zero
 var bounds:CGRect { get { CGRect(origin:.zero,size:frame.size) } set { frame.size=newValue.size } }
 var center:CGPoint { get { CGPoint(x:frame.midX,y:frame.midY) } set { frame.origin=CGPoint(x:newValue.x-frame.width/2,y:newValue.y-frame.height/2) } }
 var isHidden=false;var clipsToBounds=false;let layer=Layer()
}
final class WKWebView:View {}
struct Mapping { func unmap(_ p:SIMD2<Double>)->SIMD2<Double>? {p} }
struct VRProfile {
 var screenWidthMM:Float=147,screenHeightMM:Float=68,eyeToScreenMM:Float=42
 var lensVerticalOffsetMM:Float=0,fovScale:Float=1,k1:Float=0,k2:Float=0,chroma:Float=0
}
final class Harness {
 var profile=VRProfile()
 let view=View(),directVideoStage=View(),directVideoLensMask=View(),directVideoPointer=View()
 let cinemaEyeContainers=[View(),View()],cinemaWebPointers=[View(),View()]
 var directVideoLeft:WKWebView! = WKWebView(),directVideoRight:WKWebView! = WKWebView()
 let directVideoExitButtons=[View(),View()],liveNavigationButtons=[View(),View(),View(),View()]
 let directVideoStatusLabels=[View(),View()]
 var cinemaWebScreenActive=false
 var cinemaScreenMappings:[Mapping?]=[nil,nil]
 func updateCinemaWebScreen() {}
'''
tests = r'''
}
@main struct Tests {
 static func main() {
  var checks=0
  func check(_ ok:Bool,_ message:String) {checks+=1;precondition(ok,message)}
  let h=Harness()
  for size in [CGSize(width:800,height:400),CGSize(width:844,height:390),CGSize(width:1280,height:720),CGSize(width:1792,height:828)] {
   h.view.frame=CGRect(origin:.zero,size:size);h.layoutDirectVideoStage()
   check(h.directVideoLensMask.isHidden,"no circular mask in the active full-screen path")
   for eye in 0..<2 {
    let f=h.cinemaEyeContainers[eye].frame
    check(f.minX==CGFloat(eye)*size.width/2 && f.width==size.width/2 && f.maxY==size.height,"exact half-screen coverage without gaps")
    check(f.minY==50 && h.cinemaEyeContainers[eye].clipsToBounds,"header space is reserved and neighboring eye is isolated")
    let web=eye==0 ? h.directVideoLeft! : h.directVideoRight!
    check(web.bounds.size==f.size && !web.layer.masksToBounds && web.layer.cornerRadius==0,"hardware video is never rounded or masked")
    for x in [0.001,0.5,0.999] {for y in [0.001,0.5,0.999] {
     let point=CGPoint(x:f.minX+x*f.width,y:f.minY+y*f.height)
     let hit=h.directVideoTarget(for:point)
     check(hit?.0 === web,"all corners target their own eye")
     check(abs((hit?.1.x ?? -1)-x)<1e-8 && abs((hit?.1.y ?? -1)-y)<1e-8,"local coordinates survive nested containers")
    }}
   }
   check(h.directVideoTarget(for:CGPoint(x:10,y:10))==nil,"header cannot click through to the page")
   h.updateFlatWebPointers(CGPoint(x:0.2,y:0.7))
   check(!h.cinemaWebPointers[0].isHidden && !h.cinemaWebPointers[1].isHidden,"cursor is visible to both eyes")
   check(abs(h.cinemaWebPointers[1].center.x-h.cinemaWebPointers[0].center.x-size.width/2)<1e-8,"stereo cursor alignment")
   h.updateFlatWebPointers(nil)
   check(h.cinemaWebPointers.allSatisfy{$0.isHidden},"tracking loss hides both pointers")
  }
  for aspect in [0.8,1.0,1.2,1.4] {for offset:Float in [-8,0,8] {for k1:Float in [0,0.4,0.8] {for k2:Float in [-0.2,0,0.6] {
   h.profile.lensVerticalOffsetMM=offset;h.profile.k1=k1;h.profile.k2=k2;h.profile.chroma=0.015
   let c=VRLensMath.lensCenterUV(eye:0,profile:h.profile)
   let center=SIMD2(Double(c.x),Double(c.y))
   let factor=LensCoverage.overscan(center:center,aspect:aspect,k1:Double(k1),k2:Double(k2),chroma:Double(h.profile.chroma))
   let base=VRLensMath.frustum(eye:0,profile:h.profile),wide=h.fullEyeFrustum(eye:0,aspect:Float(aspect))
   let raw=CameraProjection(width:1280,height:720,fx:530,fy:535,cx:627,cy:355,rayScale:0.5)!
   let camera=raw.covering(x:Double(max(abs(wide.left),abs(wide.right))),y:Double(max(abs(wide.bottom),abs(wide.top))))
   for ix in 0...10 {for iy in 0...10 {
    let uv=SIMD2(Double(ix)/10,Double(iy)/10)
    let p=(uv-center)*SIMD2(aspect,1),r2=p.x*p.x+p.y*p.y
    let f=1+Double(k1)*r2+Double(k2)*r2*r2
    for channel in [-1.0,0,1] {
     let sample=center+(uv-center)*f*(1+channel*Double(h.profile.chroma))/factor
     check(sample.x>=0 && sample.x<=1 && sample.y>=0 && sample.y<=1,"warped texture samples stay within their own eye, including corners")
    }
    let sample=center+(uv-center)*f/factor
    let tangent=SIMD2(Double(wide.left)+sample.x*Double(wide.right-wide.left),Double(wide.top)-sample.y*Double(wide.top-wide.bottom))
    let original=center+(uv-center)*f
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
  h.cinemaWebScreenActive=true;h.layoutDirectVideoStage()
  check(h.directVideoLensMask.isHidden && (h.directVideoExitButtons+h.liveNavigationButtons).allSatisfy{$0.isHidden},"3D hall fills the eye with its own controls")
  print("PASS: \(checks) fullscreen coverage, optical scale, camera/hand alignment, live layout and pointer checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-fullscreen-') as directory:
    path=Path(directory)/'fullscreen.swift'
    path.write_text(lens+stubs+frustum+layout+target+pointers+tests,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/CameraGeometry.swift',path])
