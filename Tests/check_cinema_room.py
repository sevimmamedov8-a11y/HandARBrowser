"""Run production room builders and remote hit testing with a scene-graph shim.

The optional HANDAR_CINEMA_GEOMETRY_EXPORT file contains the generated geometry
for a layout preview. This is not a substitute for SceneKit/iPhone rendering.
"""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root / "HandARBrowser/CinemaHall.swift").read_text(encoding="utf-8")


def method(name):
    start = source.index("    private func " + name + "(") if "    private func " + name + "(" in source else source.index("    func " + name + "(")
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func ", "func ")


layout = source[source.index("enum CinemaHallLayout {"):source.index("/// Blue tiered auditorium")]
shim = r'''
import Foundation
func simd_length(_ v: SIMD3<Float>) -> Float { sqrt(v.x*v.x+v.y*v.y+v.z*v.z) }
func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v/simd_length(v) }
func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
 SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)
}
struct simd_quatf {
 var v=SIMD3<Float>.zero, w:Float=1
 init() {}
 init(from a:SIMD3<Float>,to b:SIMD3<Float>) {
  let c=cross(a,b); let s:Float=1+a.x*b.x+a.y*b.y+a.z*b.z
  let n=sqrt(c.x*c.x+c.y*c.y+c.z*c.z+s*s)
  v=c/n;w=s/n
 }
 init(axis:SIMD3<Float>,angle:Float){v=axis*sin(angle/2);w=cos(angle/2)}
 func rotate(_ p:SIMD3<Float>)->SIMD3<Float> {p+2*w*cross(v,p)+2*cross(v,cross(v,p))}
}
struct Transform {
 var x=SIMD3<Float>(1,0,0),y=SIMD3<Float>(0,1,0),z=SIMD3<Float>(0,0,1),p=SIMD3<Float>.zero
 func vector(_ v:SIMD3<Float>)->SIMD3<Float>{x*v.x+y*v.y+z*v.z}
 static func *(_ t:Transform,_ v:SIMD4<Float>)->SIMD4<Float>{
  SIMD4(t.vector(SIMD3(v.x,v.y,v.z))+t.p*v.w,v.w)
 }
 static func *(_ a:Transform,_ b:Transform)->Transform {
  Transform(x:a.vector(b.x),y:a.vector(b.y),z:a.vector(b.z),p:a.vector(b.p)+a.p)
 }
 var inverse:Transform {
  func dot(_ a:SIMD3<Float>,_ b:SIMD3<Float>)->Float{a.x*b.x+a.y*b.y+a.z*b.z}
  let xx=x/dot(x,x),yy=y/dot(y,y),zz=z/dot(z,z)
  return Transform(x:SIMD3(xx.x,yy.x,zz.x),y:SIMD3(xx.y,yy.y,zz.y),
                   z:SIMD3(xx.z,yy.z,zz.z),p:SIMD3(-dot(xx,p),-dot(yy,p),-dot(zz,p)))
 }
}
typealias SCNVector3=SIMD3<Float>
struct UIColor {
 var rgba:[Double]
 init(red:Double,green:Double,blue:Double,alpha:Double){rgba=[red,green,blue,alpha]}
 init(white:Double,alpha:Double){rgba=[white,white,white,alpha]}
 static let black=UIColor(white:0,alpha:1)
}
final class SCNMaterial {
 var color=UIColor.black,constant=false
 func cineLit(_ color:UIColor){self.color=color}
 func cineConstant(_ color:UIColor){self.color=color;constant=true}
}
class Geometry {
 var size:[Double]=[],kind="",materials:[SCNMaterial]=[]
 var firstMaterial:SCNMaterial? {get{materials.first}set{materials=newValue.map{[$0]} ?? []}}
}
final class SCNBox:Geometry {
 var chamferSegmentCount=1
 init(width:CGFloat,height:CGFloat,length:CGFloat,chamferRadius:CGFloat){
  super.init();kind="box";size=[Double(width),Double(height),Double(length),Double(chamferRadius)]
 }
}
final class SCNTorus:Geometry {
 var ringSegmentCount=0,pipeSegmentCount=0
 init(ringRadius:CGFloat,pipeRadius:CGFloat){
  super.init();kind="torus";size=[Double(ringRadius),Double(pipeRadius)]
 }
}
class SCNNode {
 weak var parent:SCNNode?
 var childNodes:[SCNNode]=[],geometry:Geometry?,constraints:[Int]=[]
 var position=SCNVector3.zero,scale=SCNVector3(repeating:1),eulerAngles=SCNVector3.zero
 var simdOrientation=simd_quatf(),isHidden=false,opacity:Double=1,label=""
 var simdPosition:SIMD3<Float>{get{position}set{position=newValue}}
 var presentation:SCNNode{self}
 init(geometry:Geometry?=nil){self.geometry=geometry}
 func addChildNode(_ n:SCNNode){n.parent=self;childNodes.append(n)}
 func clone()->SCNNode{
  let n=SCNNode(geometry:geometry);n.position=position;n.scale=scale;n.eulerAngles=eulerAngles
  n.simdOrientation=simdOrientation;n.label=label
  for child in childNodes{n.addChildNode(child.clone())}
  return n
 }
 func flattenedClone()->SCNNode{clone()}
 var localTransform:Transform{
  func rotate(_ v:SIMD3<Float>)->SIMD3<Float>{
   let a=simd_quatf(axis:SIMD3(1,0,0),angle:eulerAngles.x).rotate(v)
   let b=simd_quatf(axis:SIMD3(0,1,0),angle:eulerAngles.y).rotate(a)
   return simdOrientation.rotate(b)
  }
  return Transform(x:rotate(SIMD3(scale.x,0,0)),y:rotate(SIMD3(0,scale.y,0)),
                   z:rotate(SIMD3(0,0,scale.z)),p:position)
 }
 var simdWorldTransform:Transform{(parent?.simdWorldTransform ?? Transform()) * localTransform}
 var descendants:[SCNNode]{[self]+childNodes.flatMap{$0.descendants}}
}
final class CineText:SCNNode {
 func setText(_ text:String,color:UIColor){label=text}
 func fitWidth(_ width:Float){}
}
struct WorldRay{var origin:SIMD3<Float>,direction:SIMD3<Float>}
final class CineButton {
 let node=SCNNode()
 let width:Float=0.46,height:Float=0.22
 init(_ title:String){
  node.label=title
  let box=SCNBox(width:0.46,height:0.22,length:0.026,chamferRadius:0.024)
  let mat=SCNMaterial();mat.cineConstant(UIColor(red:0.1,green:0.15,blue:0.23,alpha:1))
  box.firstMaterial=mat;node.geometry=box
 }
 func setTitle(_ title:String){node.label=title}
'''
fields = r'''
}
final class Light {var intensity:Double=0}
final class CinemaHall {
 static let screenWidth=CinemaHallLayout.screenWidth,screenHeight=CinemaHallLayout.screenHeight
 static let screenDistance=CinemaHallLayout.screenDistance,screenCenterHeight=CinemaHallLayout.screenCenterHeight
 let root=SCNNode(),noticeLabel=CineText(),timeLabel=CineText(),panelTitle=CineText()
 let lightButton=CineButton("Light"),playButton=CineButton("Play"),backButton=CineButton("-10s"),fwdButton=CineButton("+10s")
 let volDownButton=CineButton("Vol -"),volUpButton=CineButton("Vol +"),restartButton=CineButton("Restart"),exitButton=CineButton("Home")
 var remotePanel:SCNNode?
 let ambientLight=Light()
 var ceilingStrips:[SCNNode]=[],lightsOn=false
 var buttons:[CineButton]{[playButton,lightButton,backButton,fwdButton,volDownButton,volUpButton,restartButton,exitButton]}
}
extension CinemaHall {
'''
tests = r'''
}
var checks=0
func check(_ value:Bool,_ text:String){precondition(value,text);checks+=1}
let hall=CinemaHall()
hall.buildRoom();hall.buildScreenArea();hall.buildSeats();hall.buildAestheticDetails();hall.buildControlPanel()
hall.setLights(false)
let eye=SIMD3<Float>(0,CinemaHallLayout.screenCenterHeight,0)
let screenHalf=CinemaHallLayout.screenWidth/2/CinemaHallLayout.screenDistance
let angle=2*atan(screenHalf)*180/Float.pi
check(angle>42 && angle<49,"screen is comfortably farther away")
check(abs(CinemaHallLayout.screenWidth/CinemaHallLayout.screenHeight-16/9)<0.001,"video keeps 16:9")
let crowns=hall.root.descendants.filter{$0.geometry?.size == [0.58,0.12,0.13,0.04]}
check(crowns.count==99,"all seating rows built")
check(crowns.contains{$0.simdWorldTransform.p.z < -1},"rows ahead")
check(crowns.contains{$0.simdWorldTransform.p.z > 1},"rows behind")
for node in crowns where node.simdWorldTransform.p.z < -0.1 {
 let p=node.simdWorldTransform.p
 let bottom=CinemaHallLayout.screenCenterHeight-CinemaHallLayout.screenHeight/2
 let line=eye.y+(bottom-eye.y)*(-p.z/CinemaHallLayout.screenDistance)
 check(p.y+0.06 < line,"front chair must not obscure the movie's bottom edge")
}
let before=hall.root.descendants.count
hall.setLights(true);hall.setLights(false)
check(hall.root.descendants.count==before,"light toggling must not rebuild geometry")
check(hall.ambientLight.intensity>0 && hall.ambientLight.intensity<400,"dim room remains legible")
let panel=hall.buttons[0].node.parent!
func blocks(_ node:SCNNode, eye:SIMD3<Float>, target:SIMD3<Float>)->Bool {
 guard let box=node.geometry as? SCNBox else{return false}
 let inv=node.simdWorldTransform.inverse
 let a=inv * SIMD4(eye,1),b=inv * SIMD4(target,1)
 let delta=b-a
 var near:Float=0,far:Float=1
 for axis in 0..<3 {
  let half=Float(box.size[axis])/2
  if abs(delta[axis])<0.000001 {
   if abs(a[axis])>half{return false}
  } else {
   let t1=(-half-a[axis])/delta[axis],t2=(half-a[axis])/delta[axis]
   near=max(near,min(t1,t2));far=min(far,max(t1,t2))
   if near>far{return false}
  }
 }
 return near>0.0001 && near<0.995
}
let roomNodes=hall.root.descendants.filter{node in
 !panel.descendants.contains{$0 === node}
}
check(hall.buttons.allSatisfy{$0.node.parent === panel && $0.node.constraints.isEmpty},"shared remote transform")
let p=panel.simdWorldTransform
check(p.p.x>0 && p.p.z<0,"remote is forward and right")
for x:Float in [-CinemaHallLayout.remoteWidth/2,CinemaHallLayout.remoteWidth/2] {
 for y:Float in [-CinemaHallLayout.remoteHeight/2,CinemaHallLayout.remoteHeight/2] {
  let q=p * SIMD4<Float>(x,y,0,1)
  check(q.x / -q.z > screenHalf+0.05,"remote cannot cover the movie")
 }
}
for (i,button) in hall.buttons.enumerated() {
 for x:Float in [-0.18,0,0.18] {
  for y:Float in [-0.08,0,0.08] {
   let world=button.node.simdWorldTransform * SIMD4<Float>(x,y,0,1)
   let target=SIMD3<Float>(world.x,world.y,world.z)
   let ray=WorldRay(origin:eye,direction:simd_normalize(target-eye))
   let hits=hall.buttons.indices.filter{hall.buttons[$0].hitTest(ray:ray)}
   check(hits==[i],"tilted/scaled remote ray must hit only the intended key")
   check(!roomNodes.contains{blocks($0,eye:eye,target:target)},"a chair must not hide the remote")
  }
 }
}
for row in 0..<4 {
 let world=p * SIMD4<Float>(0,0.37-Float(row)*0.32,0.04,1)
 let ray=WorldRay(origin:eye,direction:simd_normalize(SIMD3(world.x,world.y,world.z)-eye))
 check(!hall.buttons.contains{$0.hitTest(ray:ray)},"gap between keys cannot click")
}
for node in hall.root.descendants {
 let t=node.simdWorldTransform
 check(t.p.x.isFinite && t.p.y.isFinite && t.p.z.isFinite,"finite room transforms")
}
// Re-centering moves both the room and the ray together.
hall.root.simdPosition=SIMD3(3,1,-2)
hall.root.eulerAngles.y=0.7
let movedEye4=hall.root.simdWorldTransform * SIMD4(eye,1)
let movedEye=SIMD3(movedEye4.x,movedEye4.y,movedEye4.z)
for (i,button) in hall.buttons.enumerated() {
 let target=button.node.simdWorldTransform.p
 let ray=WorldRay(origin:movedEye,direction:simd_normalize(target-movedEye))
 check(hall.buttons.indices.filter{hall.buttons[$0].hitTest(ray:ray)} == [i],"remote works after recenter")
}
hall.root.simdPosition = .zero;hall.root.eulerAngles = .zero
if let path=ProcessInfo.processInfo.environment["HANDAR_CINEMA_GEOMETRY_EXPORT"] {
 func arr(_ v:SIMD3<Float>)->[Float]{[v.x,v.y,v.z]}
 let nodes:[[String:Any]]=hall.root.descendants.compactMap{n in
  guard let g=n.geometry else{return nil}
  let t=n.simdWorldTransform
  let m=g.firstMaterial ?? SCNMaterial()
  return ["kind":g.kind,"size":g.size,"x":arr(t.x),"y":arr(t.y),"z":arr(t.z),"p":arr(t.p),
          "color":m.color.rgba,"constant":m.constant,"label":n.label]
 }
 let data=try JSONSerialization.data(withJSONObject:["nodes":nodes,"eye":arr(eye),
     "screen":[CinemaHallLayout.screenWidth,CinemaHallLayout.screenHeight,CinemaHallLayout.screenDistance]])
 try data.write(to:URL(fileURLWithPath:path))
}
print("PASS: \(checks) cinema layout, clear sightlines, remote hit areas and recenter checks")
'''
builders = "\n".join(method(name) for name in [
    "boxNode", "buildRoom", "buildScreenArea", "buildSeats", "buildAestheticDetails", "buildControlPanel", "setLights"
])
if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="handar-room-") as directory:
        script = Path(directory) / "room.swift"
        script.write_text(shim + method("hitTest") + fields + builders + tests + "\n" + layout, encoding="utf-8")
        run_swift_sources([script])
