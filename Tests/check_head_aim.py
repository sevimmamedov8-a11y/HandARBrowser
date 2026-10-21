"""Execute head-input routing and freshness rules from production Swift."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')

def method(name):
    start = source.index('    private func '+name+'(')
    end = source.index('{', start)+1
    depth = 1
    while depth:
        depth += (source[end] == '{')-(source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

shim = r'''
import Foundation
struct Matrix {
 var columns=(SIMD4<Float>(1,0,0,0),SIMD4<Float>(0,1,0,0),SIMD4<Float>(0,0,1,0),SIMD4<Float>(0,0,0,1))
}
func simd_length(_ p:SIMD3<Float>)->Float{sqrt(p.x*p.x+p.y*p.y+p.z*p.z)}
func simd_normalize(_ p:SIMD3<Float>)->SIMD3<Float>{p/simd_length(p)}
final class Node {var simdWorldTransform=Matrix();var simdWorldPosition=SIMD3<Float>.zero;var isHidden=false}
struct WorldRay {
 var origin:SIMD3<Float>,direction:SIMD3<Float>
 func point(at t:Float)->SIMD3<Float>{origin+direction*t}
}
struct Frame {var timestamp:Double;var valid=true}
final class Tracking {
 var latestFrameCopy:Frame?
 func isCurrent(_ f:Frame)->Bool{f.valid}
}
var clock=0.0
struct Hit {var localX:Float=0,localY:Float=0}
struct Comfort {var isPeeking=false}
final class Controls {
 static let screenWidth:Float=6.4,screenHeight:Float=3.6
 var comfort=Comfort(),screenWorldTransform=Matrix()
 var gate=ReleaseClickGate<Int>(),clicks=0,updates=0,cancels=0,headAiming=false
 var lastRay:WorldRay?
 func cancelInput(){gate.cancel();cancels+=1}
 @discardableResult func update(ray:WorldRay?,pinch:Bool,allowBegin:Bool,dwell:Bool)->Bool {
  precondition(!pinch && !allowBegin && dwell)
  updates+=1;lastRay=ray
  let target:Int? = ray.map { abs($0.direction.x)<0.5 ? 0 : 1 }
  if gate.update(target:target,down:pinch,allowBegin:allowBegin,dwell:dwell,at:clock) != nil {clicks+=1}
  return true
 }
 func setHeadAiming(_ v:Bool,head:Node){headAiming=v}
}
typealias CinemaHall=Controls
final class Resettable {var resets=0;func reset(){resets+=1}}
final class Menu {var updates=0;func updatePointerControlMode(){updates+=1}}
final class Harness {
 var inVR=true,pointerControlMode=PointerControlMode.head
 var usesHeadAim:Bool{pointerControlMode == .head}
 var headAimSession=HeadAimSession(),handClickMode=HandClickMode.pinch
 var lensCalibrationView:Int?,cinemaActive=false,securityGameActive=false,cinemaWebScreenActive=false,panoramaActive=false
 var controllerButtonDown=true,dragging=true,resizing=true,windowUpdates=0,releases=0,dots=0
 var lastWindowRay:WorldRay?,lastWebPointer:CGPoint?
 let tracking=Tracking(),headNode=Node(),controllerHandRoot=Node(),rayNode=Node()
 let leftHandSkeletonNode=Node(),rightHandSkeletonNode=Node()
 let cinemaHall=Controls(),securityGame=Controls(),window=Controls(),panorama=Controls()
 let handOwnership=Resettable(),hands=Resettable(),menuSwipe=Resettable()
 var menu:Menu?=Menu(),toolbarClickGate=ReleaseClickGate<Int>()
 func releasePointer(){releases+=1;window.cancelInput()}
 func hidePointer(){};func hidePointerDot(){}
 func cancelHandInteraction(){headAimSession.reset();releasePointer();cinemaHall.cancelInput();securityGame.cancelInput()}
 func endDrag(){dragging=false};func endResize(){resizing=false};func updateVRDesktopStatus(){}
 func showPointerDot(at p:SIMD3<Float>,transform:Matrix,active:Bool){precondition(!active);dots+=1}
 func planeHit(ray:WorldRay,transform:Matrix)->Hit?{Hit()}
 func updateCinemaWebPointers(_ p:CGPoint?){lastWebPointer=p}
 func handlePanoramaRay(_ ray:WorldRay,down:Bool,allowBegin:Bool,dwell:Bool){
  panorama.update(ray:ray,pinch:down,allowBegin:allowBegin,dwell:dwell)
 }
 func handleWindowRay(_ ray:WorldRay,down:Bool,allowBegin:Bool,dwell:Bool,at time:Double){
  windowUpdates+=1;lastWindowRay=ray
  window.update(ray:ray,pinch:down,allowBegin:allowBegin,dwell:dwell)
 }
'''

tests = r'''
}
var count=0
func check(_ value:Bool,_ message:String){precondition(value,message);count+=1}
var session=HeadAimSession()
check(!session.update(at:0,poseTime:0,current:true),"settling starts without click")
for i in 1...6 {let t=Double(i)*0.05;check(!session.update(at:t,poseTime:t,current:true),"no early dwell")}
check(session.update(at:0.36,poseTime:0.36,current:true),"ready after settling")
check(!session.update(at:1,poseTime:0.36,current:true),"stale camera blocks input")
check(!session.update(at:1,poseTime:1,current:false),"wrong camera generation blocks input")
check(!session.update(at:1,poseTime:2,current:true),"future pose blocks input")
check(!session.update(at:.nan,poseTime:1,current:true),"invalid time blocks input")
let h=Harness()
func frames(_ start:Int,_ end:Int){
 for i in start...end {clock=Double(i)*0.05;h.tracking.latestFrameCopy=Frame(timestamp:clock);h.updateHeadAim(at:clock)}
}
frames(0,80)
check(h.window.clicks==1,"one dwell during four seconds on same window target")
check(h.lastWindowRay?.direction == SIMD3<Float>(0,0,-1),"head forward defines ray")
check(h.controllerHandRoot.isHidden,"controller cannot compete with head input")
h.headNode.simdWorldTransform.columns.2=SIMD4(-1,0,0,0)
frames(81,110)
check(h.window.clicks==2 && h.lastWindowRay?.direction == SIMD3<Float>(1,0,0),"turning changes ray and target")
h.headNode.simdWorldTransform.columns.2=SIMD4(0,0,1,0)
frames(111,120)
let clicks=h.window.clicks
clock=6.6;h.tracking.latestFrameCopy=nil;h.updateHeadAim(at:clock)
check(h.window.clicks==clicks,"loss cannot complete unfinished click")
frames(133,145)
check(h.window.clicks==clicks,"reacquisition requires new full dwell")
frames(146,170)
check(h.window.clicks==clicks+1,"reacquired pose can click after settling and dwell")
let calls=h.windowUpdates
h.inVR=false;frames(171,180)
check(h.windowUpdates==calls,"no input outside VR")
h.inVR=true;h.lensCalibrationView=1;frames(181,190)
check(h.windowUpdates==calls,"head input cannot click fixed calibration overlay")
h.lensCalibrationView=nil;h.cancelHandInteraction();h.cinemaActive=true;h.cinemaWebScreenActive=true
frames(191,240)
check(h.cinemaHall.clicks==1 && h.windowUpdates==calls,"cinema routes only to controls, never to video input")
check(h.lastWebPointer != nil,"cinema web cursor remains visible without sending clicks")
h.cinemaHall.comfort.isPeeking=true;frames(241,242)
check(h.lastWebPointer==nil,"camera peek hides film pointer")
h.cinemaActive=false;h.securityGameActive=true;h.cancelHandInteraction();frames(243,290)
check(h.securityGame.clicks==1,"Security VR uses same one-shot dwell")
let old=UserDefaults.standard.object(forKey:"handar.pointer.mode.v1")
h.setPointerControlMode(.hand)
check(!h.usesHeadAim && PointerControlMode.load() == .hand,"mode persists")
check(h.handClickMode == .pinch,"switching preserves pinch preference")
check(!h.dragging && !h.resizing && !h.controllerButtonDown,"switch cancels other interactions")
check(h.hands.resets==1 && h.handOwnership.resets==1 && h.menuSwipe.resets==1,"switch clears stale hand state")
check(h.menu?.updates==1,"native settings selector stays in sync")
let gameUpdates=h.securityGame.updates;frames(291,300)
check(h.securityGame.updates==gameUpdates,"hand mode disables head writes")
h.setPointerControlMode(.head)
check(h.cinemaHall.headAiming && PointerControlMode.load() == .head,"mode change updates dock attachment")
UserDefaults.standard.set(old,forKey:"handar.pointer.mode.v1")
let travel=Harness()
travel.panoramaActive=true
for i in 0...60 {
 clock=Double(i)*0.05
 travel.tracking.latestFrameCopy=Frame(timestamp:clock)
 travel.updateHeadAim(at:clock)
}
check(travel.panorama.clicks==1,"one travel dwell, including long hold")
check(travel.windowUpdates==0 && travel.cinemaHall.updates==0 && travel.securityGame.updates==0,"travel input stays out of hidden apps")
clock=5
travel.updateHeadAim(at:clock)
check(travel.panorama.cancels>0,"stale head frame cancels travel dwell")
print("PASS: \(count) head aim freshness, routing, dwell, tracking recovery and mode-switch checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-head-') as directory:
    main=Path(directory)/'main.swift'
    main.write_text(shim+method('setPointerControlMode')+'\n'+method('updateHeadAim')+tests,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift', main])

assert 'guard inVR, !usesHeadAim || lensCalibrationView != nil else' in method('handleHands')
assert 'if !self.usesHeadAim || self.lensCalibrationView != nil' in source
assert '!self.usesHeadAim, self.handOwnership.hand != nil' in source
for name in ['handleControllerStick','handleControllerGyro','updateControllerHand']:
    assert 'guard !usesHeadAim || lensCalibrationView != nil else' in method(name)
assert 'aim-head' in source and 'aim-hand' in source
assert 'updateHeadAim(at: CACurrentMediaTime())' in source
print('PASS: exclusive hand/controller ownership, paused Vision inference and both mode selectors')
