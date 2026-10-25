// Minimal geometry-recording platform stand-ins for executing the production game on Windows.
import Foundation
typealias SCNVector3 = SIMD3<Float>
func simd_dot(_ a:SIMD3<Float>,_ b:SIMD3<Float>)->Float { a.x*b.x+a.y*b.y+a.z*b.z }
func simd_dot(_ a:SIMD4<Float>,_ b:SIMD4<Float>)->Float { a.x*b.x+a.y*b.y+a.z*b.z+a.w*b.w }
func simd_length(_ a:SIMD3<Float>)->Float { sqrt(simd_dot(a,a)) }
func simd_normalize(_ a:SIMD3<Float>)->SIMD3<Float> { a/max(0.000001,simd_length(a)) }
func simd_cross(_ a:SIMD3<Float>,_ b:SIMD3<Float>)->SIMD3<Float> { SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x) }
struct simd_float3x3 { var columns:(SIMD3<Float>,SIMD3<Float>,SIMD3<Float>) }
struct simd_float4x4 {
    var columns:(SIMD4<Float>,SIMD4<Float>,SIMD4<Float>,SIMD4<Float>) = (SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,1,0),SIMD4(0,0,0,1))
}
struct simd_quatf {
    var vector = SIMD4<Float>(0,0,0,1)
    init() {}
    init(angle:Float,axis:SIMD3<Float>) { let v = simd_normalize(axis)*sin(angle/2);vector = SIMD4(v.x,v.y,v.z,cos(angle/2)) }
    init(_ m:simd_float3x3) { self.init(angle:atan2(m.columns.2.x,m.columns.2.z),axis:SIMD3(0,1,0)) }
    init(from:SIMD3<Float>,to:SIMD3<Float>) {
        let a=simd_normalize(from),b=simd_normalize(to),d=simd_dot(a,b)
        if d < -0.999 { self.init(angle:.pi,axis:SIMD3(0,1,0)) }
        else { self.init(); let v=simd_cross(a,b);let q=SIMD4(v.x,v.y,v.z,1+d);vector=q/sqrt(max(0.000001,simd_dot(q,q))) }
    }
    func act(_ p:SIMD3<Float>)->SIMD3<Float> {
        let q=SIMD3(vector.x,vector.y,vector.z),t=simd_cross(q,p)*2
        return p+t*vector.w+simd_cross(q,t)
    }
}
struct UIColor: Equatable {
    var red:CGFloat,green:CGFloat,blue:CGFloat,alpha:CGFloat
    init(red:CGFloat,green:CGFloat,blue:CGFloat,alpha:CGFloat) { self.red=red;self.green=green;self.blue=blue;self.alpha=alpha }
    init(white:CGFloat,alpha:CGFloat) { self.init(red:white,green:white,blue:white,alpha:alpha) }
    static let white=Self(white:1,alpha:1), clear=Self(white:0,alpha:0), systemCyan=Self(red:0,green:0.8,blue:1,alpha:1)
    func withAlphaComponent(_ a:CGFloat)->Self { Self(red:red,green:green,blue:blue,alpha:a) }
}
class SCNProperty { var contents:Any? }
class SCNMaterial {
    enum Lighting { case constant,lambert }
    var lightingModel=Lighting.constant,isDoubleSided=false
    let diffuse=SCNProperty()
}
class SCNGeometry { var firstMaterial:SCNMaterial?; var materials:[SCNMaterial]=[] }
class SCNPlane:SCNGeometry { var width:CGFloat,height:CGFloat; init(width:CGFloat,height:CGFloat) {self.width=width;self.height=height} }
class SCNBox:SCNGeometry { var chamferSegmentCount=1; init(width:CGFloat,height:CGFloat,length:CGFloat,chamferRadius:CGFloat){} }
class SCNSphere:SCNGeometry { var segmentCount=24; init(radius:CGFloat){} }
class SCNCone:SCNGeometry { var radialSegmentCount=24; init(topRadius:CGFloat,bottomRadius:CGFloat,height:CGFloat){} }
class SCNCylinder:SCNGeometry { var radialSegmentCount=24; init(radius:CGFloat,height:CGFloat){} }
class SCNTorus:SCNGeometry { var ringSegmentCount=24,pipeSegmentCount=12; init(ringRadius:CGFloat,pipeRadius:CGFloat){} }
class SCNBillboardConstraint {}
class SCNLight {
    enum Kind {case ambient,directional}
    var type=Kind.ambient,intensity=0,categoryBitMask=0,castsShadow=false
}
class SCNNode {
    var geometry:SCNGeometry?,light:SCNLight?,constraints:[SCNBillboardConstraint]?
    var isHidden=false,position=SCNVector3.zero,eulerAngles=SCNVector3.zero,scale=SCNVector3(repeating:1)
    var simdPosition:SIMD3<Float> { get {position} set {position=newValue} }
    var simdEulerAngles:SIMD3<Float> { get {eulerAngles} set {eulerAngles=newValue} }
    var simdOrientation=simd_quatf()
    var simdWorldTransform=simd_float4x4()
    var simdWorldPosition:SIMD3<Float> { (parent?.simdWorldPosition ?? .zero)+position }
    weak var parent:SCNNode?
    var childNodes:[SCNNode]=[]
    init(geometry:SCNGeometry?=nil) {self.geometry=geometry}
    func addChildNode(_ node:SCNNode) {node.removeFromParentNode();childNodes.append(node);node.parent=self}
    func removeFromParentNode(){parent?.childNodes.removeAll{$0===self};parent=nil}
    func flattenedClone()->SCNNode {self}
    func clone()->SCNNode {let n=SCNNode(geometry:geometry);n.position=position;n.eulerAngles=eulerAngles;n.isHidden=isHidden;for c in childNodes{n.addChildNode(c.clone())};return n}
    func convertPosition(_ p:SCNVector3,to:SCNNode?)->SCNVector3 {simdWorldPosition+simdOrientation.act(p)}
}
class SCNScene {let rootNode=SCNNode()}
class TMLabel:SCNNode {
    var text=""
    func setText(_ value:String,color:UIColor = .white,meters:Float){text=value}
}
class TMSoundBank {
    var events:[TMSound]=[]
    func prepare(){}
    func setTimeScale(_ value:Double){}
    func play(_ sound:TMSound,volume:Float=0.9){events.append(sound)}
    func stopAll(){}
}
class DwellProgressRing:SCNNode {func show(on:SCNNode?,progress:Double){isHidden=on==nil}}
struct WorldRay {let origin:SIMD3<Float>,direction:SIMD3<Float>}
