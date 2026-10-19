"""Actual optical helpers, profile migration and native replicator configuration."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
root=Path(__file__).resolve().parent.parent
source=(root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
profile=source[source.index('struct VRProfile:'):source.index('/// Границы пирамиды видимости')]
replicator=source[source.index('final class MonoscopicWebReplicatorView:'):source.index('final class DirectVideoLensMaskView:')]
stubs=r'''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
struct utsname {var machine:(CChar,CChar,CChar,CChar)=(105,111,115,0)}
@discardableResult func uname(_ p:inout utsname)->Int32 {0}
final class UIScreen {static let main=UIScreen();var nativeBounds=CGRect(x:0,y:0,width:1170,height:2532);var scale:CGFloat=3}
struct Transform {var x:CGFloat,y:CGFloat,z:CGFloat}
func CATransform3DMakeTranslation(_ x:CGFloat,_ y:CGFloat,_ z:CGFloat)->Transform {Transform(x:x,y:y,z:z)}
class CALayer {}
final class CAReplicatorLayer:CALayer {var instanceCount=0;var instanceDelay:Double=100;var instanceTransform=Transform(x:0,y:0,z:0)}
class UIView {class var layerClass:AnyClass {CALayer.self};var layer:CALayer=CAReplicatorLayer()}
'''
tests=r'''
@main struct Tests {
 static func main() throws {
  var count=0
  func check(_ ok:Bool,_ message:String){count+=1;precondition(ok,message)}
  func close(_ a:Double,_ b:Double)->Bool {abs(a-b)<1e-6}
  let profile=VRProfile.makeDefault()
  check(abs(Double(profile.screenWidthMM)-2532.0/460*25.4)<1e-5,"iPhone 13 long dimension derives from native pixels and 460 ppi")
  check(abs(Double(profile.screenHeightMM)-1170.0/460*25.4)<1e-5,"iPhone 13 short dimension uses the same physical scale")
  let encoded=try JSONEncoder().encode(profile)
  var old=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
  old.removeValue(forKey:"screenHorizontalOffsetMM");old.removeValue(forKey:"rightEyeVerticalOffsetMM")
  old["lensSeparationMM"]=65.25;old["lensVerticalOffsetMM"]=1.25
  let migrated=try JSONDecoder().decode(VRProfile.self,from:JSONSerialization.data(withJSONObject:old))
  check(migrated.lensSeparationMM==65.25 && migrated.lensVerticalOffsetMM==1.25,"old settings survive migration")
  check(migrated.screenHorizontalOffsetMM==nil && migrated.rightEyeVerticalOffsetMM==nil,"new optional alignment values default to zero on old profiles")
  var adjusted=migrated;adjusted.screenHorizontalOffsetMM=0.8;adjusted.rightEyeVerticalOffsetMM = -0.35
  check(try JSONDecoder().decode(VRProfile.self,from:JSONEncoder().encode(adjusted))==adjusted,"fine calibration survives encoding/decoding")
  let copy=MonoscopicWebReplicatorView();copy.copyOffset=CGPoint(x:380,y:2)
  let layer=copy.layer as! CAReplicatorLayer
  check(layer.instanceCount==2 && layer.instanceDelay==0,"one source is copied with no time offset")
  check(layer.instanceTransform.x==380 && layer.instanceTransform.y==2 && layer.instanceTransform.z==0,"only a translation changes the copy, with no independent camera or scale")
  for d in [52.0,63,76] {for x in [-8.0,0,8] {for y in [-8.0,0,8] {for dy in [-4.0,0,4] {
   let width=2532.0/460*25.4,height=1170.0/460*25.4
   let left=MonoViewGeometry.lensCenter(eye:0,screenWidth:width,screenHeight:height,separation:d,horizontal:x,vertical:y,rightVertical:dy)
   let right=MonoViewGeometry.lensCenter(eye:1,screenWidth:width,screenHeight:height,separation:d,horizontal:x,vertical:y,rightVertical:dy)
   let shift=MonoViewGeometry.replicaShift(left:left,right:right,width:844,height:390)
   check(close(shift.x/844*width,d),"output optical axes are separated by the configured physical lens distance")
   check(close((left.x*422+(0.5+right.x*0.5)*844)/2/844*width,width/2+x),"horizontal trim moves the phone center without changing separation")
   check(close(shift.y/390*height,-dy),"right-eye vertical trim has the requested physical amount")
   let viewport=MonoViewGeometry.sourceViewport(width:844,height:390,shift:shift)
   for u in [0.0,0.5,1] {for v in [0.0,0.5,1] {
    let p=viewport.origin+SIMD2(u,v)*viewport.size,q=p+shift
    check(p.x>=(-1e-8) && p.x<=422.000001 && q.x>=421.999999 && q.x<=844.000001,"shared crop never leaks content between physical eye halves")
    check(p.y>=(-1e-8) && p.y<=390.000001 && q.y>=(-1e-8) && q.y<=390.000001,"vertical correction preserves an identical crop in both eyes")
   }}
   for k1 in [0.0,0.4,0.8] {for k2 in [-0.2,0.0,0.6] {for u in [0.2,0.5,0.8] {for v in [0.2,0.5,0.8] {
    let uv=SIMD2(u,v),aspect=422.0/390
    let l=MonoViewGeometry.displayUV(source:uv,center:left,aspect:aspect,k1:k1,k2:k2)!
    let r=MonoViewGeometry.displayUV(source:uv,center:right,aspect:aspect,k1:k1,k2:k2)!
    check(close(r.x-l.x,right.x-left.x)&&close(r.y-l.y,right.y-left.y),"every point in the right image is the translated copy of the left point, including distortion")
    for (display,center) in [(l,left),(r,right)] {
     let p=(display-center)*SIMD2(aspect,1),r2=p.x*p.x+p.y*p.y
     let reconstructed=SIMD2<Double>(0.5,0.5)+(display-center)*(1+k1*r2+k2*r2*r2)
     check(close(reconstructed.x,uv.x)&&close(reconstructed.y,uv.y),"calibration pattern and compositor reconstruct the same canonical source pixel")
    }
   }}}}
  }}}}
  print("PASS: \(count) iPhone 13 geometry, profile migration, zero-delay copying, lens calibration and eye isolation checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-mono-') as directory:
    path=Path(directory)/'mono.swift'
    path.write_text(stubs+profile+replicator+tests,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/CameraGeometry.swift',path])
assert source.count('directVideoLeft = makeDirectVideoWebView(role: "left")')==1
assert 'directVideoRight' not in source
assert 'rightRenderer.render(' not in source
assert 'rightCameraNode' not in source
assert 'float2 off = float2(0.0)' in source
print('PASS: no independent right camera, scene render, web page or video player in production')
