"""Execute comfort state, production room transforms and dwell actions."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
import check_cinema_room as room

root = Path(__file__).resolve().parent.parent
hall = (root / 'HandARBrowser/CinemaHall.swift').read_text(encoding='utf-8')
controller = (root / 'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
state = hall[hall.index('struct CinemaComfortState {'):hall.index('/// Dimensions in metres')]

shim = room.shim.replace('v=c/n;w=s/n', 'if n < 0.00001 { v=SIMD3(0,1,0);w=0 } else { v=c/n;w=s/n }')
shim = shim.replace(' func rotate(_ p:', ' func act(_ p:SIMD3<Float>)->SIMD3<Float>{rotate(p)}\n func rotate(_ p:')
shim = shim.replace(' var x=SIMD3<Float>', ''' var columns:(SIMD4<Float>,SIMD4<Float>,SIMD4<Float>,SIMD4<Float>) {
 get{(SIMD4(x,0),SIMD4(y,0),SIMD4(z,0),SIMD4(p,1))}
 set{x=SIMD3(newValue.0.x,newValue.0.y,newValue.0.z);y=SIMD3(newValue.1.x,newValue.1.y,newValue.1.z)
 z=SIMD3(newValue.2.x,newValue.2.y,newValue.2.z);p=SIMD3(newValue.3.x,newValue.3.y,newValue.3.z)}
 }
 var x=SIMD3<Float>''')
shim = shim.replace(' var position=SCNVector3.zero,scale=SCNVector3(repeating:1),eulerAngles=SCNVector3.zero', ''' var explicitTransform:Transform?
 var position=SCNVector3.zero {didSet{explicitTransform=nil}}
 var scale=SCNVector3(repeating:1) {didSet{explicitTransform=nil}}
 var eulerAngles=SCNVector3.zero {didSet{explicitTransform=nil}}''')
shim = shim.replace(' var simdOrientation=simd_quatf(),isHidden=false,opacity:Double=1,label=""', ''' var simdOrientation=simd_quatf() {didSet{explicitTransform=nil}}
 var isHidden=false,opacity:Double=1,label=""''')
shim = shim.replace(' var localTransform:Transform{', ' var simdTransform:Transform{localTransform}\n var localTransform:Transform{\n  if let t=explicitTransform{return t}')
shim = shim.replace(' var simdWorldTransform:Transform{(parent?.simdWorldTransform ?? Transform()) * localTransform}', ''' func removeFromParentNode(){parent?.childNodes.removeAll{$0 === self};parent=nil}
 var simdWorldTransform:Transform{
 get{(parent?.simdWorldTransform ?? Transform()) * localTransform}
 set{explicitTransform=(parent?.simdWorldTransform.inverse ?? Transform()) * newValue}
 }''')
shim = shim.replace(' func setTitle(_ title:String)', ' func setHighlight(_ value:Bool){}\n func setTitle(_ title:String)')
fields = room.fields.replace('final class CinemaHall {', '''
final class SCNScene {let rootNode=SCNNode()}
typealias simd_float4x4=Transform
let matrix_identity_float4x4=Transform()
func simd_mul(_ a:Transform,_ b:Transform)->Transform{a*b}
var clock:Double=0
func CACurrentMediaTime()->Double{clock}
final class DwellProgressRing {
 var isHidden=false
 func show(on target:SCNNode?,progress:Double){}
}
struct UIImpactFeedbackGenerator {
 enum Style {case light,medium}
 init(style:Style){}
 func impactOccurred(){}
}
final class CinemaHall {''')
fields = fields.replace(' let root=SCNNode()', ''' var scene:SCNScene? = SCNScene()
 var comfort=CinemaComfortState(),isRunning=true
 let comfortRoot=SCNNode()
 var latchedComfortButton:CineButton?
 let summonButton=CineButton("Remote"),reclineButton=CineButton("Recline"),peekButton=CineButton("Camera")
 var comfortButtons:[CineButton]{[summonButton,reclineButton,peekButton]}
 var allButtons:[CineButton]{buttons+comfortButtons}
 var buttonClickGate=ReleaseClickGate<ObjectIdentifier>()
 let dwellRing=DwellProgressRing()
 var screenWorldTransform=matrix_identity_float4x4
 var onRemoteRequested:(()->Void)?,onPeekRequested:(()->Void)?,onRealignRequested:(()->Void)?
 var onInteraction:(()->Void)?,onToggleLights:((Bool)->Void)?,onPlayPause:(()->Void)?
 var onSeek:((Double)->Void)?,onVolume:((Float)->Void)?,onRestart:(()->Void)?,onExitRequested:(()->Void)?
 let root=SCNNode()''')
methods = '\n'.join(room.method(name) for name in [
    'boxNode','buildControlPanel','setHeadAiming','attachComfortControls','refreshComfortTitles','restoreRemote',
    'toggleRemote','setPeeking','tick','cancelPendingRecline','cancelInput','update','setLights',
    'alignViewer','alignReclinedViewer','updateScreenTransform'])

def controller_method(name):
    start=controller.index('    private func '+name+'(')
    end=controller.index('{',start)+1
    depth=1
    while depth:
        depth+=(controller[end]=='{')-(controller[end]=='}');end+=1
    return controller[start:end].replace('private func','func')

integration = r''' 
}
struct Frame {var timestamp:Double;var valid=true}
final class Tracking {
 var latestFrameCopy:Frame?
 func isCurrent(_ frame:Frame)->Bool{frame.valid}
}
final class View {var alpha:Double=1}
struct Profile {var passthrough=false}
extension CinemaHall {func setNotice(_ text:String){}}
final class Harness {
 var cinemaActive=true,controllerButtonDown=false
 let cinemaHall=CinemaHall(),tracking=Tracking(),liveWebReplicator=View()
 let browserPlaneNode=SCNNode(),controllerHandRoot=SCNNode()
 var profile=Profile()
 var cameraPassthroughRequested:Bool{cinemaActive ? cinemaHall.comfort.isPeeking : profile.passthrough}
 func cancelHandInteraction(){cinemaHall.cancelInput()}
 func hidePointer(){}
 func updateCinemaWebPointers(_ point:CGPoint?){}
'''
integration += '\n'.join(controller_method(n) for n in ['toggleCinemaPeek','setCinemaPeeking','tickCinemaComfort'])

tests = r''' 
}
var count=0
func check(_ v:Bool,_ reason:String){precondition(v,reason);count+=1}
var state=CinemaComfortState()
check(!state.requestRecline(at:0),"wait for comfortable head pose")
check(!state.advance(at:2.9).realign,"no early rotation")
check(state.advance(at:3).realign && state.isReclined,"one delayed alignment")
check(!state.advance(at:3.1).realign,"no repeated rotation")
check(state.requestRecline(at:4) && !state.isReclined,"return upright")
_ = state.requestRecline(at:5);state.setPeeking(true)
check(!state.advance(at:8).realign,"peek cancels pending rotation")
check(!state.requestRecline(at:9) && state.reclineDeadline == nil,"no alignment while seeing room")
state.setPeeking(false);_ = state.requestRecline(at:10)
check(!state.advance(at:30).realign && !state.isReclined,"suspended countdown cannot rotate room later")
_ = state.requestRecline(at:40);_ = state.requestRecline(at:41)
check(state.reclineDeadline == nil,"second request cancels countdown")
state.toggleRemote(at:50);check(state.remoteSummoned,"summon")
check(!state.advance(at:61.9).restoreRemote,"stay for interaction")
state.keepRemote(at:61.9)
check(!state.advance(at:62).restoreRemote,"hover renews timeout")
check(state.advance(at:73.9).restoreRemote && !state.remoteSummoned,"return after inactivity")
state.toggleRemote(at:80);state.setPeeking(true)
check(!state.remoteSummoned,"camera hides summoned remote")
state=CinemaComfortState();state.toggleRemote(at:.nan)
check(!state.remoteSummoned,"invalid clock rejected")

let hall=CinemaHall(),head=SCNNode()
head.position=SIMD3(0,CinemaHall.screenCenterHeight,0)
hall.buildControlPanel();hall.attachComfortControls(to:head)
for pitch:Float in [0,0.3,0.8,1.4,Float.pi/2] {
 for yaw:Float in [-2,-0.7,0,0.9,2] {
  let forward=SIMD3<Float>(sin(yaw)*cos(pitch),sin(pitch),-cos(yaw)*cos(pitch))
  let eye=SIMD3<Float>(1,0.7,-2)
  hall.alignReclinedViewer(origin:eye,forward:forward)
  let screen=hall.screenWorldTransform.p
  check(simd_length(screen-(eye+forward*CinemaHall.screenDistance))<0.001,"screen ahead when reclining")
  let seatEye=hall.root.simdTransform * SIMD4<Float>(0,CinemaHall.screenCenterHeight,0,1)
  check(simd_length(SIMD3(seatEye.x,seatEye.y,seatEye.z)-eye)<0.001,"room pivots around seated eye")
  check(abs(simd_length(hall.screenWorldTransform.x)-1)<0.001,"no scale distortion")
 }
}
let stable=hall.screenWorldTransform.p
hall.alignReclinedViewer(origin:.zero,forward:SIMD3(.nan,0,0))
check(hall.screenWorldTransform.p==stable,"invalid pose leaves screen unchanged")
hall.alignViewer(origin:head.position,forward:SIMD3(0,0,-1))
clock=100
hall.toggleRemote(headTransform:head.simdWorldTransform,at:clock)
let panel=hall.remotePanel!
check(simd_length(panel.simdWorldTransform.p-(head.position+SIMD3(0,0,-1.65)))<0.001,"remote in front of current view")
for (i,b) in hall.buttons.enumerated() {
 let target=b.node.simdWorldTransform.p
 let ray=WorldRay(origin:head.position,direction:simd_normalize(target-head.position))
 check(hall.buttons.indices.filter{hall.buttons[$0].hitTest(ray:ray)} == [i],"summoned keys keep accurate ray hits")
}
clock=113;hall.tick(at:clock)
check(!hall.comfort.remoteSummoned && panel.position==CinemaHallLayout.remotePosition,"timeout restores original position")
var peeks=0
hall.onPeekRequested={peeks+=1;hall.setPeeking(!hall.comfort.isPeeking)}
let eye=head.position,target=hall.peekButton.node.simdWorldTransform.p
let ray=WorldRay(origin:eye,direction:simd_normalize(target-eye))
for i in 0...100 {clock=120+Double(i)*0.04;_ = hall.update(ray:ray,pinch:false,dwell:true)}
check(peeks==1 && hall.comfort.isPeeking,"holding Camera must not repeatedly toggle")
check(hall.root.isHidden && hall.comfortRoot.parent === head,"return control survives camera mode")
_ = hall.update(ray:nil,pinch:false,dwell:true)
for i in 0...60 {clock=125+Double(i)*0.04;_ = hall.update(ray:ray,pinch:false,dwell:true)}
check(peeks==2 && !hall.comfort.isPeeking,"leave and dwell again returns to hall")

hall.setHeadAiming(true,head:head)
check(hall.comfortRoot.parent === hall.scene?.rootNode,"head aim dock is anchored in world")
let dockBefore=hall.comfortRoot.simdWorldTransform.p
head.position.x += 0.5
check(simd_length(hall.comfortRoot.simdWorldTransform.p-dockBefore)<0.0001,"dock must not chase head")
for button in hall.comfortButtons {
 let target=button.node.simdWorldTransform.p
 let direction=simd_normalize(target-head.position)
 check(button.hitTest(ray:WorldRay(origin:head.position,direction:direction)),"all dock buttons reachable by turning head")
}
hall.setPeeking(true)
check(hall.comfortRoot.parent === hall.scene?.rootNode && hall.root.isHidden,"camera return dock survives without hand")
hall.setHeadAiming(false,head:head)
check(hall.comfortRoot.parent === head,"hand mode restores head-attached controls")
hall.setPeeking(false)

let square=[SIMD2<Double>(-50,-40),SIMD2(550,-40),SIMD2(550,450),SIMD2(-50,450)]
for eye in 0..<2 {
 let low=Double(eye)*500,high=low+500
 let result=CinemaControlMask.clipped(square,minX:low,maxX:high,maxY:400)
 check(result.count==4,"clipped quadrilateral")
 for p in result {check(p.x>=low && p.x<=high && p.y>=0 && p.y<=400,"mask cannot leak into other eye")}
}
check(CinemaControlMask.clipped([],minX:0,maxX:500,maxY:400).isEmpty,"empty mask")
check(CinemaControlMask.clipped([SIMD2(.nan,0),SIMD2(1,0),SIMD2(1,1)],minX:0,maxX:500,maxY:400).isEmpty,"invalid mask")
let main=Harness()
main.cinemaHall.buildControlPanel()
clock=200;main.tracking.latestFrameCopy=Frame(timestamp:clock)
main.toggleCinemaPeek()
check(main.cinemaHall.comfort.isPeeking && main.liveWebReplicator.alpha==0,"camera hides video presentation")
check(main.browserPlaneNode.isHidden && main.cameraPassthroughRequested,"camera also works when ordinary background camera is disabled")
check(!main.profile.passthrough,"peek preserves saved background preference")
main.toggleCinemaPeek()
check(!main.cinemaHall.comfort.isPeeking && main.liveWebReplicator.alpha==1 && !main.browserPlaneNode.isHidden,"return restores hall")
clock=202;main.toggleCinemaPeek()
check(!main.cinemaHall.comfort.isPeeking,"stale frame cannot enter camera mode")
main.tracking.latestFrameCopy=Frame(timestamp:clock);main.toggleCinemaPeek()
clock=203;main.tickCinemaComfort(at:clock)
check(!main.cinemaHall.comfort.isPeeking && main.liveWebReplicator.alpha==1,"tracking loss returns to hall")
_ = main.cinemaHall.comfort.requestRecline(at:204)
main.tracking.latestFrameCopy=nil;clock=205;main.tickCinemaComfort(at:clock)
check(main.cinemaHall.comfort.reclineDeadline==nil,"tracking loss cancels pending alignment")
main.cinemaActive=false;main.tracking.latestFrameCopy=Frame(timestamp:clock);main.toggleCinemaPeek()
check(!main.cinemaHall.comfort.isPeeking && !main.cameraPassthroughRequested,"cinema actions stop outside hall")
print("PASS: \(count) comfort state, reclined geometry, remote hits, dwell, camera recovery and eye-mask checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-comfort-') as directory:
    script = Path(directory) / 'main.swift'
    script.write_text(shim + room.method('hitTest') + fields + methods + integration + tests + '\n' + state + room.layout, encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/CameraGeometry.swift',script])

# The camera mode must not create a second player, reload a page or change play intent.
start=controller.index('    private func setCinemaPeeking(')
end=controller.index('    private func updateCinemaControlOcclusion(',start)
peek=controller[start:end]
assert 'liveWebReplicator.alpha = peeking ? 0 : 1' in peek
assert all(word not in peek for word in ['.load(', '.reload(', '.play(', '.pause(', 'evaluateJavaScript'])
assert 'previous.mask = mask' in controller
assert 'cameraPassthroughRequested && hasCamera' in controller
assert 'cinemaHall.attachComfortControls(to: headNode)' in controller
print('PASS: camera presentation keeps one player and independent nested occlusion masks')
