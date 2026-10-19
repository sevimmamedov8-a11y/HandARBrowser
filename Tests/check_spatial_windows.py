"""Execute real spatial-web projection/layout/input against simple scene stand-ins."""
from pathlib import Path
import tempfile, plistlib
from swift_test_support import run_swift_sources
root=Path(__file__).resolve().parent.parent
source=(root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
def block(start,end):
    return source[source.index(start):source.index(end,source.index(start))].replace('private func','func').replace('private var','var')
lens=source[source.index('struct EyeFrustum {'):source.index('    static func projection(_ frustum:')]+'\n}\n'
homography=block('struct CinemaScreenHomography {','private final class WeakScriptMessageHandler:')
projection=block('    private func projectedCinemaCorner(','    private func handleCinemaWebHands(')
layout=block('    private func layoutDirectVideoStage()','    private func navigateLiveBrowser(')
input_method=block('    private func updateDirectVideoInput(','    private func cancelHandInteraction(')
properties=block('    private var liveWebTransform:','    private var directVideoLeft:')
stubs=r'''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
func simd_length(_ p:SIMD2<Float>)->Float {sqrt(p.x*p.x+p.y*p.y)}
struct Matrix {
 var yaw:Float=0,t=SIMD3<Float>(0,0,0)
 func rotate(_ p:SIMD3<Float>)->SIMD3<Float> {SIMD3(cos(yaw)*p.x+sin(yaw)*p.z,p.y,-sin(yaw)*p.x+cos(yaw)*p.z)}
 var inverse:Matrix {let r=Matrix(yaw:-yaw);return Matrix(yaw:-yaw,t:r.rotate(-t))}
 static func *(_ m:Matrix,_ p:SIMD4<Float>)->SIMD4<Float> {let v=m.rotate(SIMD3(p.x,p.y,p.z))+m.t*p.w;return SIMD4(v,p.w)}
}
typealias simd_float4x4=Matrix
final class Camera {var simdWorldTransform=Matrix()}
struct Transform {
 var m11:CGFloat=1,m21:CGFloat=0,m41:CGFloat=0,m12:CGFloat=0,m22:CGFloat=1,m42:CGFloat=0,m14:CGFloat=0,m24:CGFloat=0,m44:CGFloat=1
}
let CATransform3DIdentity=Transform()
enum CATransaction {static func begin(){};static func commit(){};static func setDisableActions(_ b:Bool){}}
final class Layer {var transform=Transform();var anchorPoint=CGPoint.zero;var position=CGPoint.zero}
class View {
 var frame=CGRect.zero,bounds=CGRect.zero,center=CGPoint.zero
 var clipsToBounds=false,isHidden=false;let layer=Layer()
 func bringSubviewToFront(_ v:View){}
}
final class WKWebView:View {}
final class Bridge {var points:[CGPoint]=[];func update(normalizedPoint:CGPoint,pinch:Bool,webView:WKWebView,allowBegin:Bool,dwell:Bool){points.append(normalizedPoint)}}
final class CinemaHall {static let screenWidth:Float=4.55,screenHeight:Float=2.56;var screenWorldTransform=Matrix(t:SIMD3(0,1,-4))}
struct VRProfile {var screenWidthMM:Float=147,screenHeightMM:Float=68,eyeToScreenMM:Float=42,lensVerticalOffsetMM:Float=0,fovScale:Float=1,k1:Float=0,k2:Float=0,chroma:Float=0}
final class Harness {
 let view=View(),directVideoStage=View(),directVideoLensMask=View()
 let directVideoLeft:WKWebView! = WKWebView(),directVideoRight:WKWebView! = WKWebView()
 let cinemaEyeContainers=[View(),View()],cinemaWebPointers=[View(),View()],directVideoStatusLabels=[View(),View()]
 let directVideoExitButtons=[View(),View()],liveNavigationButtons=[View(),View(),View(),View()]
 let leftCameraNode=Camera(),rightCameraNode=Camera(),cinemaHall=CinemaHall()
 let directLeftInput=Bridge(),directRightInput=Bridge()
 var cinemaScreenMappings:[CinemaScreenHomography?]=[nil,nil]
 var profile=VRProfile(),directVideoActive=true,cinemaWebScreenActive=false
 var browserWorldTransform:Matrix?=Matrix(t:SIMD3(0,0,-2.15))
 var browserWorldWidth:Float=2.9,browserWorldHeight:Float=1.63
'''
tests=r'''
}
@main struct Tests {
 static func main() {
  var count=0
  func check(_ value:Bool,_ message:String){count+=1;precondition(value,message)}
  func close(_ a:Double,_ b:Double)->Bool{abs(a-b)<1e-4}
  let h=Harness();h.view.bounds=CGRect(x:0,y:0,width:844,height:390)
  h.leftCameraNode.simdWorldTransform.t.x = -0.0315;h.rightCameraNode.simdWorldTransform.t.x = 0.0315
  h.layoutDirectVideoStage()
  check(h.directVideoLensMask.isHidden,"no lens overlay adds a black frame")
  check((h.directVideoExitButtons+h.liveNavigationButtons).allSatisfy{$0.isHidden},"no fullscreen native toolbar")
  let corners=[SIMD3<Float>(-1.45,0.815,0.012),SIMD3<Float>(1.45,0.815,0.012),SIMD3<Float>(1.45,-0.815,0.012),SIMD3<Float>(-1.45,-0.815,0.012)]
  for eye in 0..<2 {
   let web=eye==0 ? h.directVideoLeft! : h.directVideoRight!
   check(web.bounds.size==CGSize(width:1280,height:720),"browser retains the same viewport as the desktop")
   let mapping=h.cinemaScreenMappings[eye]!
   let quad=corners.map{h.projectedCinemaCorner($0,eye:eye)!}
   check(quad.allSatisfy{$0.x>0 && $0.x<422 && $0.y>0 && $0.y<390},"floating window leaves camera background around it")
   let cameraX:Double=eye==0 ? -0.0315:0.0315
   let base=VRLensMath.frustum(eye:eye,profile:h.profile)
   for i in 0..<4 {
    let worldX=Double(corners[i].x)-cameraX,worldY=Double(corners[i].y),depth=2.15-Double(corners[i].z)
    let expected=SIMD2((worldX/depth-Double(base.left))/Double(base.right-base.left)*422,(Double(base.top)-worldY/depth)/Double(base.top-base.bottom)*390)
    check(close(quad[i].x,expected.x)&&close(quad[i].y,expected.y),"live page occupies the same world plane as the menu")
   }
   for uv in [SIMD2<Double>(0.1,0.2),SIMD2(0.5,0.5),SIMD2(0.9,0.8)] {
    let p=mapping.map(uv)!,back=mapping.unmap(p)!
    check(close(back.x,uv.x)&&close(back.y,uv.y),"spatial input inverses visible page projection")
    let transform=web.layer.transform,pixel=CGPoint(x:uv.x*1280,y:uv.y*720)
    let divisor=Double(transform.m14*pixel.x+transform.m24*pixel.y+transform.m44)
    let actual=SIMD2(Double(transform.m11*pixel.x+transform.m21*pixel.y+transform.m41)/divisor,Double(transform.m12*pixel.x+transform.m22*pixel.y+transform.m42)/divisor)
    check(close(actual.x,p.x)&&close(actual.y,p.y),"UIKit transform and hand hit projection agree")
   }
   check(h.directVideoStatusLabels[eye].frame.maxY<web.bounds.height,"error notice stays inside the world window")
  }
  let original=h.cinemaScreenMappings[0]!.map(SIMD2(0.5,0.5))!
  h.browserWorldTransform!.t.x=0.3;h.updateCinemaWebScreen()
  let moved=h.cinemaScreenMappings[0]!.map(SIMD2(0.5,0.5))!
  check(moved.x>original.x,"dragging the world panel moves the live page with it")
  h.leftCameraNode.simdWorldTransform.yaw=0.2;h.updateCinemaWebScreen()
  let turned=h.cinemaScreenMappings[0]!.map(SIMD2(0.5,0.5))!
  check(abs(turned.x-moved.x)>1,"page responds to head rotation instead of following the screen")
  h.leftCameraNode.simdWorldTransform.yaw=0
  h.browserWorldWidth=1.9;h.browserWorldHeight=1.9*1.63/2.9;h.updateCinemaWebScreen()
  let width=h.cinemaScreenMappings[0]!.map(SIMD2(1.0,0.0))!.x-h.cinemaScreenMappings[0]!.map(SIMD2(0.0,0.0))!.x
  check(width<300,"size changes alter the spatial page without changing the headset viewport")
  let uv=CGPoint(x:0.25,y:0.75)
  h.updateDirectVideoInput(normalizedPoint:uv,pinch:false,dwell:true)
  check(h.directLeftInput.points==[uv]&&h.directRightInput.points==[uv],"both eyes receive the same spatial dwell target")
  check(h.cinemaWebPointers.allSatisfy{!$0.isHidden},"cursor projects into both eyes")
  h.updateCinemaWebPointers(nil);check(h.cinemaWebPointers.allSatisfy{$0.isHidden},"tracking cancellation clears both cursors")
  h.browserWorldTransform=nil;h.updateCinemaWebScreen()
  check(h.directVideoLeft.isHidden&&h.directVideoRight.isHidden,"recenter hides the old page until its anchor is ready")
  h.cinemaWebScreenActive=true;h.updateCinemaWebScreen()
  check(!h.directVideoLeft.isHidden&&h.directVideoLeft.bounds.size==CGSize(width:960,height:540),"3D cinema retains its separate screen")
  check(SpatialWindowSizing.nextWidth(after:1.9)==2.9 && SpatialWindowSizing.nextWidth(after:2.9)==3.8 && SpatialWindowSizing.nextWidth(after:3.8)==1.9,"three size presets cycle")
  let key="handar.test.spatial.\(UUID())",defaults=UserDefaults(suiteName:key)!
  defer{defaults.removePersistentDomain(forName:key)}
  check(SpatialWindowSizing.restoredWidth(defaults:defaults,fallback:2.9)==2.9,"no saved size uses default")
  for (saved,expected): (Double,Float) in [(1.9,1.9),(3.8,3.8),(100,3.8),(-10,0.72),(Double.nan,2.9)] {
   defaults.set(saved,forKey:SpatialWindowSizing.storageKey)
   check(SpatialWindowSizing.restoredWidth(defaults:defaults,fallback:2.9)==expected,"saved sizes are restored and validated")
  }
  print("PASS: \(count) world-window placement, head motion, resizing, stereo input and recovery checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-spatial-') as directory:
    path=Path(directory)/'spatial.swift'
    path.write_text(lens+homography+stubs+properties+projection+layout+input_method+tests,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/CameraGeometry.swift',path])
with (root/'HandARBrowser/Info.plist').open('rb') as stream:
    info=plistlib.load(stream)
assert isinstance(info.get('UILaunchScreen'),dict),'modern iPhone display launch declaration missing'
assert info['UIStatusBarHidden'] is True
shader=source[source.index('fragment float4 vr_fragment'):source.index('    private func makePipeline()')]
assert 'return float4(0.0, 0.0, 0.0, 1.0)' not in shader,'shader still has artificial black edge branches'
assert 'color * vignette' not in shader
assert 'camUV = clamp(camUV' in shader
print('PASS: modern fullscreen launch declaration and no artificial black-edge shader paths')
