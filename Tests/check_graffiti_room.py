"""Build production room props with geometry-recording SceneKit stand-ins."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/GraffitiStudio.swift').read_text(encoding='utf-8')
props_source = (root/'HandARBrowser/GraffitiProps.swift').read_text(encoding='utf-8')
props_class = props_source[props_source.index('final class GraffitiProps {'):]

def method(name):
    start = source.index('    private func ' + name + '(')
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

shim = r'''
import Foundation
typealias SCNVector3 = SIMD3<Float>
let SCNVector3Zero = SCNVector3.zero
struct simd_quatf { var up = SIMD3<Float>(0,1,0); init() {}; init(from:SIMD3<Float>,to:SIMD3<Float>) { up = to } }
func simd_length(_ v: SIMD3<Float>) -> Float { sqrt(v.x*v.x+v.y*v.y+v.z*v.z) }
struct WorldRay { let origin: SIMD3<Float>, direction: SIMD3<Float>; func point(at t: Float) -> SIMD3<Float> { origin+direction*t } }
struct UIColor: Hashable {
 var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
 init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { self.red=red;self.green=green;self.blue=blue;self.alpha=alpha }
 init(white: CGFloat, alpha: CGFloat) { self.init(red:white,green:white,blue:white,alpha:alpha) }
 static let systemCyan = UIColor(red:0,green:1,blue:1,alpha:1)
 static let black = UIColor(white: 0, alpha: 1)
 static let white = UIColor(white: 1, alpha: 1), darkGray = UIColor(white: 0.3, alpha: 1)
 init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
  precondition((0...1).contains(hue)); self.init(red:hue, green:saturation, blue:brightness, alpha:alpha)
 }
 func withAlphaComponent(_ value: CGFloat) -> UIColor { UIColor(red:red,green:green,blue:blue,alpha:value) }
}
enum Lighting { case constant, lambert }
final class SCNLight { enum Kind { case ambient, directional }; var type = Kind.ambient, intensity = 0, categoryBitMask = 0, color = UIColor.white, castsShadow = false }
final class Property { var contents: Any? }
final class SCNMaterial {
 var lightingModel = Lighting.constant, isDoubleSided = false, writesToDepthBuffer = true
 let diffuse = Property(), multiply = Property()
}
final class SCNGeometrySource { let vertices: [SCNVector3]; init(vertices:[SCNVector3]) { self.vertices = vertices }; init(normals:[SCNVector3]) { vertices = [] } }
final class SCNGeometryElement { enum Kind { case triangles }; init(indices:[Int32],primitiveType:Kind) {} }
typealias SCNGeometry = Geometry
class Geometry {
 init() {}
 init(sources:[SCNGeometrySource],elements:[SCNGeometryElement]) {
  for v in sources.flatMap({ $0.vertices }) { halfSize = SIMD3(max(halfSize.x,abs(v.x)),max(halfSize.y,abs(v.y)),max(halfSize.z,abs(v.z))) }
 }
 var materials: [SCNMaterial] = []
 var firstMaterial: SCNMaterial? { get { materials.first } set { materials = newValue.map { [$0] } ?? [] } }
 var halfSize = SCNVector3.zero
}
final class SCNSphere: Geometry { var segmentCount = 48; init(radius: CGFloat) { super.init(); halfSize = SIMD3(repeating:Float(radius)) } }
final class SCNCone: Geometry {
 init(topRadius: CGFloat, bottomRadius: CGFloat, height: CGFloat) {
  super.init();halfSize = SCNVector3(Float(max(topRadius,bottomRadius)),Float(height*0.5),Float(max(topRadius,bottomRadius)))
 }
}
final class SCNBox: Geometry {
 init(width: CGFloat, height: CGFloat, length: CGFloat, chamferRadius: CGFloat) {
  super.init(); halfSize = SCNVector3(Float(width), Float(height), Float(length)) * 0.5
 }
}
final class SCNCylinder: Geometry {
 var radialSegmentCount = 48, heightSegmentCount = 1
 init(radius: CGFloat, height: CGFloat) { super.init();halfSize = SCNVector3(Float(radius), Float(height * 0.5), Float(radius)) }
}
final class SCNTorus: Geometry {
 var ringSegmentCount = 48, pipeSegmentCount = 12
 init(ringRadius: CGFloat, pipeRadius: CGFloat) {
  super.init(); halfSize = SCNVector3(Float(ringRadius + pipeRadius), Float(pipeRadius), Float(ringRadius + pipeRadius))
 }
}
struct SCNAction {
 static func rotateBy(x: CGFloat, y: CGFloat, z: CGFloat, duration: Double) -> Self { precondition(duration >= 10);return Self() }
 static func repeatForever(_ action: Self) -> Self { action }
}
class SCNNode {
 var light: SCNLight?
 var geometry: Geometry?, position = SCNVector3.zero, eulerAngles = SCNVector3.zero
 var scale = SCNVector3(repeating: 1), isHidden = false, isPaused = false
 var name: String?
 weak var parent: SCNNode?
 var simdPosition: SIMD3<Float> { get { position } set { position = newValue } }
 var simdWorldPosition: SIMD3<Float> {
  get { (parent?.simdWorldPosition ?? .zero) + position }
  set { position = newValue - (parent?.simdWorldPosition ?? .zero) }
 }
 var simdWorldOrientation = simd_quatf()
 var childNodes: [SCNNode] = [], constraints: [Int] = [], animated = false, flattened = false
 init(geometry: Geometry? = nil) { self.geometry = geometry }
 func addChildNode(_ node: SCNNode) { node.removeFromParentNode();childNodes.append(node);node.parent = self }
 func removeFromParentNode() { parent?.childNodes.removeAll { $0 === self }; parent = nil }
 func convertPosition(_ point:SCNVector3,to node:SCNNode?) -> SCNVector3 { simdWorldPosition+simdWorldOrientation.up*point.y+SIMD3(point.x,0,point.z) }
 func flattenedClone() -> SCNNode { flattened = true;return self }
 func runAction(_ action: SCNAction) { animated = true }
}
final class CineText: SCNNode {
 var text = "", width: Float = 0
 func setText(_ value: String, color: UIColor) { text = value }
 func fitWidth(_ value: Float) { width = value }
}
final class CineButton { let node = SCNNode() }
final class Harness {
 var legMotion = GraffitiLegMotion(), legNodes: [SCNNode] = []
 let radioButton = CineButton(); var radioNode: SCNNode?
 let room = SCNNode(), sculptureMaterial = SCNMaterial(), floorGrid = SCNNode()
 var roomSculpture: SCNNode?, preferences = GraffitiPreferences()
 let props = GraffitiProps()
 let can = SCNNode(), mist = SCNNode(), canMaterial = SCNMaterial()
 var roomAccents: [(SCNMaterial, Bool)] = [], mood = GraffitiRoomMood.neon, rainbow = false, colorIndex = 0
 let colors: [(String, UIColor)] = (0..<8).map { (String($0), UIColor(red: CGFloat($0)/8, green: 0.4, blue: 0.7, alpha: 1)) }
'''
tests = r'''
}
@main struct Tests {
 static func main() {
  var count = 0
  func check(_ value: Bool, _ message: String) { precondition(value, message);count += 1 }
  let h = Harness();h.buildRoomDecor()
  var nodes: [SCNNode] = []
  func visit(_ node: SCNNode) { nodes.append(node);node.childNodes.forEach(visit) }
  visit(h.room)
  let meshes = nodes.filter { $0.geometry != nil }
  check(meshes.count > 480 && meshes.count < 650, "detail increases within a fixed mesh budget")
  check(nodes.filter { $0.animated }.count == 1, "only one slowly animated object")
  check(h.room.childNodes.contains { $0.flattened }, "static decor is merged once")
  let materials = Set(meshes.compactMap { $0.geometry?.firstMaterial }.map { ObjectIdentifier($0) })
  check(materials.count < 42, "detailed props still share a bounded material palette")
  for node in meshes {
   var size = node.geometry!.halfSize * node.scale
   if abs(node.eulerAngles.x) > 1 { size = SCNVector3(size.x, size.z, size.y) }
   let p = node.simdWorldPosition
   check(abs(p.x) + size.x <= GraffitiRoomLayout.span * 0.5 + 0.04 &&
         abs(p.z) + size.z <= GraffitiRoomLayout.span * 0.5 + 0.04, "props fit inside expanded room")
   check(p.y - size.y >= GraffitiRoomLayout.floorY - 0.055 &&
         p.y + size.y <= GraffitiRoomLayout.ceilingY + 0.04, "props meet floor and ceiling")
   check(!(p.z < 0 && abs(p.x) < 3.5 && p.y > GraffitiRoomLayout.floorY + 0.2 && p.y < 1.5),
         "front central painting area remains clear")
   if let cylinder = node.geometry as? SCNCylinder { check(cylinder.radialSegmentCount <= 16, "cans and speakers use small meshes") }
  }
  let football = h.room.childNodes.first { $0.name == "Футбольный мяч" }
  check(football != nil && football!.childNodes.count == 2,"football is one grabbable root with a highlight")
  let sculpture = nodes.first { $0.animated }!
  check(sculpture.geometry?.firstMaterial === h.sculptureMaterial, "selected paint color can update the sculpture without rebuilding it")
  let sign = nodes.compactMap { $0 as? CineText }.first!
  check(sign.text == "HANDAR  /  SPRAY LAB" && sign.position.z > 3 && sign.constraints.isEmpty,
        "studio sign stays attached to the rear wall")
  check(h.roomAccents.count == 2, "both accent groups found after merging static geometry")
  let neon = h.roomAccents.map { $0.0.diffuse.contents as! UIColor }
  h.mood = .sunset;h.updateRoomMood()
  check(h.roomAccents.map { $0.0.diffuse.contents as! UIColor } != neon, "sunset changes actual merged materials")
  h.mood = .mint;h.updateRoomMood();h.mood = .neon;h.updateRoomMood()
  check(h.roomAccents.map { $0.0.diffuse.contents as! UIColor } == neon, "lighting cycles back without rebuilding room")
  check(h.room.childNodes.filter { $0.name != nil }.count == 16, "all small props have independent pickable roots")
  h.preferences.grid = false; h.preferences.animation = false; h.preferences.brightness = 0; h.applyRoomSettings()
  check(h.floorGrid.isHidden && h.roomSculpture?.isPaused == true, "settings control actual grid and animation nodes")
  check(meshes.allSatisfy { ($0.geometry?.firstMaterial?.multiply.contents as? UIColor) == UIColor(white: 0.55, alpha: 1) }, "brightness changes actual room materials")
  h.buildCan()
  let body = h.can.childNodes.first!.geometry!
  check(body.halfSize.y * 2 * h.can.scale.y < 0.10 && h.can.scale.x == h.can.scale.y, "spray can is uniformly smaller than ten centimeters")
  check(h.can.isHidden && h.mist.isHidden, "small can starts hidden")
  check(h.paintColor(at: 1) == h.colors[0].1, "solid paint preserves chosen color")
  h.rainbow = true
  check(h.paintColor(at: 1) != h.paintColor(at: 2), "rainbow changes color over time")
  check(h.paintColor(at: .nan) == h.colors[0].1, "invalid hue time uses valid solid color")
  _ = h.paintColor(at: -1)

  h.buildLegs()
  check(h.legNodes.count == 2 && h.legNodes.allSatisfy { $0.parent === h.room && $0.isHidden },"legs are separate initially hidden children of the room")
  check(h.legNodes.allSatisfy { $0.flattened && $0.childNodes.count == 4 },"legs merge four small meshes without a physics body")

  // Execute the actual prop manager, not just its gesture latch.
  let props = GraffitiProps(), playground = SCNNode()
  var picked = 0, confirmed = 0
  props.onPickColor = { picked += $0+1 }; props.onInteraction = { _, gain in precondition(gain>0 && gain<=1);confirmed += 1 }
  props.add(parts: [SCNNode()], name: "A", center: SCNVector3(0,0,-2), halfSize: SIMD3(0.1,0.1,0.1), color: 0, in: playground)
  props.add(parts: [SCNNode()], name: "B", center: SCNVector3(1,0,-2), halfSize: SIMD3(0.1,0.1,0.1), color: 1, in: playground)
  let a = playground.childNodes[0], b = playground.childNodes[1]
  let rayA = WorldRay(origin: .zero, direction: SIMD3(0,0,-1))
  let rayB = WorldRay(origin: .zero, direction: SIMD3(1,0,-2)/sqrt(5))
  func feed(_ time: Double, hand: TrackedHand = .left, ray: WorldRay? = rayA,
            fist: Bool = false, open: Bool = false, generation: UInt64? = 1, blocked: Bool = false) {
   props.update(hand: hand, generation: generation, fist: fist, open: open, ray: ray, distance: 0.5,
     orientation: simd_quatf(), blocked: blocked, ready: true, at: time)
  }
  for t in [0.0,0.04,0.08] { feed(t,open:true);feed(t,hand:.right,open:true) }
  for t in [0.12,0.16,0.20,0.24] { feed(t,fist:true);feed(t,hand:.right,fist:true) }
  check(picked == 1 && confirmed == 1 && props.holdingAnything, "two fists cannot take the same object twice")
  check(a.simdWorldPosition.z > -0.9 && b.simdWorldPosition == SIMD3(1,0,-2), "selected prop follows near hand without moving others")
  for t in [0.28,0.32,0.36,0.40] { feed(t,fist:true);feed(t,hand:.right,ray:rayB,fist:true) }
  check(picked == 3 && confirmed == 2, "second hand can hold a different object")
  let holdA = a.simdWorldPosition
  feed(0.44,ray:rayB,fist:true)
  check(a.simdWorldPosition != holdA, "moving palm ray carries held prop")
  for i in 12...61 {
   let t = Double(i)*0.04
   feed(t,ray:rayB,open:true);feed(t,hand:.right,ray:rayB)
  }
  check(props.isHeld(a) && props.isHeld(b), "almost two seconds retains both objects")
  feed(2.48,ray:rayB,open:true);feed(2.48,hand:.right,ray:rayB)
  check(!props.isHeld(a) && props.isHeld(b), "only left releases after two seconds")
  check(a.simdWorldPosition.y > -1, "release starts flight without teleport to floor")
  check(props.blocksPainting(.left), "drop gesture remains blocked from painting")
  feed(2.52,hand:.right,ray:rayB,fist:true,generation:2)
  check(!props.holdingAnything && b.simdWorldPosition.y < -1, "new identity cannot inherit held prop")
  for i in 0..<300 { props.tick(at:2.52+Double(i)/60,ready:true) }
  check(a.simdWorldPosition.y < -1 && confirmed >= 3, "released object falls and plays impact sound")
  props.reset()
  check(a.simdWorldPosition == SIMD3(0,0,-2) && b.simdWorldPosition == SIMD3(1,0,-2), "reset restores original shelf positions")
  for t in [1.0,1.04,1.08] { feed(t,open:true) }
  for t in [1.12,1.16,1.20,1.24] { feed(t,fist:true) }
  check(props.holdingAnything, "grab after reset")
  props.tick(at:1.46,ready:true)
  check(!props.holdingAnything && a.simdWorldPosition.y < -1, "watchdog settles carry without a new hand delivery")
  props.reset()
  for t in [2.0,2.04,2.08] { feed(t,open:true) }
  for t in [2.12,2.16,2.20,2.24] { feed(t,fist:true) }
  feed(2.28,fist:true,blocked:true)
  check(props.holdingAnything, "crossing palette preserves actual carry")
  props.clear()
  check(playground.childNodes.isEmpty && !props.holdingAnything, "app exit removes movable nodes and ownership")
  let closeProps = GraffitiProps()
  var selected = -1;closeProps.onPickColor = { selected = $0 }
  closeProps.add(parts:[SCNNode()],name:"near",center:SCNVector3(0.15,0,-1.9),halfSize:SIMD3(0.1,0.1,0.1),color:0,in:playground)
  closeProps.add(parts:[SCNNode()],name:"aimed",center:SCNVector3(0,0,-2),halfSize:SIMD3(0.1,0.1,0.1),color:1,in:playground)
  for step in 0...6 {
   closeProps.update(hand:.left,generation:1,fist:step>=3,open:step<3,ray:rayA,distance:0.5,
     orientation:simd_quatf(),blocked:false,ready:true,at:Double(step)*0.04)
  }
  check(selected == 1, "pointed can wins over a slightly nearer adjacent can inside assist cone")

  let ballProps = GraffitiProps(), ballRoom = SCNNode()
  let ballNode = ballProps.add(parts:[SCNNode()],name:"football",center:SCNVector3(0,0,-2),halfSize:SIMD3(repeating:0.111),sound:.rubber,ball:true,in:ballRoom)
  var ballHits: [Float] = []
  ballProps.onInteraction = { sound, gain in if sound == .rubber { ballHits.append(gain) } }
  for i in 0...54 {
   ballProps.update(hand:.right,generation:1,fist:i<4,open:i>=4,ray:rayA,distance:0.5,
     orientation:simd_quatf(),blocked:false,ready:true,at:10+Double(i)*0.04)
  }
  check(!ballProps.isHeld(ballNode),"football uses the same two-second release")
  for i in 0..<480 { ballProps.tick(at:12.16+Double(i)/60,ready:true) }
  check(!ballHits.isEmpty && ballHits.allSatisfy { $0>0 && $0<=1 },"actual ball produces scaled rubber impact sounds")
  check(abs(ballNode.simdPosition.y-(GraffitiRoomLayout.floorY+0.028+0.111))<0.002,"actual ball keeps spherical height after falling and rotating")
  check(ballNode.eulerAngles != .zero,"actual released object rotates even with a stationary hand")
  let kickProps = GraffitiProps(), kickRoom = SCNNode()
  let ballY = GraffitiRoomLayout.floorY+0.139
  let kickBall = kickProps.add(parts:[SCNNode()],name:"ball",center:SIMD3(0,ballY,-0.4),halfSize:SIMD3(repeating:0.111),sound:.rubber,ball:true,in:kickRoom)
  func kickFeet(_ z:Float, old:Float? = nil) -> [GraffitiFootPose] {
   [GraffitiFootPose(center:SIMD3(0,GraffitiRoomLayout.floorY+0.075,z),forward:SIMD3(0,0,-1),previous:SIMD3(0,GraffitiRoomLayout.floorY+0.075,old ?? z),velocity:SIMD3(0,0,-1)),
    GraffitiFootPose(center:SIMD3(3,ballY,0),forward:SIMD3(0,0,-1),previous:SIMD3(3,ballY,0),velocity:.zero)]
  }
  var kicks = 0
  kickProps.onInteraction = { sound, gain in if sound == .rubber { kicks += 1; check(gain > 0 && gain <= 1,"foot sound gain bounded") } }
  kickProps.updateFeet(kickFeet(0),continuous:true,at:20)
  kickProps.updateFeet(kickFeet(-0.24,old:0),continuous:true,at:20.02)
  check(kicks == 1 && kickProps.savedState()[0].moving,"actual contact activates saved prop physics and sound")
  let kickedAt = kickBall.simdPosition
  kickProps.tick(at:20.02,ready:true);kickProps.tick(at:20.06,ready:true)
  check(kickBall.simdPosition.z < kickedAt.z && kickBall.eulerAngles != .zero,"actual kicked prop moves and rotates")
  kickProps.reset()
  kickProps.updateFeet(kickFeet(-0.24),continuous:true,at:21)
  check(kicks == 1 && !kickProps.savedState()[0].moving,"reset under a foot does not create another kick")
  kickProps.updateFeet(kickFeet(0),continuous:true,at:21.02)
  let lowRay = WorldRay(origin:SIMD3(0,ballY,0),direction:SIMD3(0,0,-1))
  for i in 0...6 { kickProps.update(hand:.left,generation:1,fist:true,open:false,ray:lowRay,distance:0.5,
    orientation:simd_quatf(),blocked:false,ready:true,at:22+Double(i)*0.04) }
  check(kickProps.isHeld(kickBall),"ball still grabbable after a kick")
  let heldPosition = kickBall.simdPosition
  kickProps.updateFeet(kickFeet(heldPosition.z+0.14),continuous:true,at:22.26)
  check(kickBall.simdPosition == heldPosition && kicks == 1,"foot cannot knock a held ball out of hand")
  kickProps.cancel()
  kickProps.updateFeet(kickFeet(0),continuous:false,at:23)
  kickProps.updateFeet(kickFeet(kickBall.simdPosition.z+0.14),continuous:true,at:23.02)
  check(kicks == 1,"tracking recovery does not kick overlapping ball")

  let paintTools = GraffitiProps(), toolRoom = SCNNode()
  toolRoom.simdPosition = SIMD3(3,0,0)
  let toolNode = paintTools.add(parts:[SCNNode()],name:"brush",center:SCNVector3(-3,0,-2),halfSize:SIMD3(0.02,0.19,0.02),brushRadius:0.003,in:toolRoom)
  for i in 0...6 { paintTools.update(hand:.left,generation:1,fist:true,open:false,ray:rayA,distance:0.5,
     orientation:simd_quatf(),blocked:false,ready:true,at:Double(i)*0.04) }
  let tip = paintTools.brushTip(.left)!
  check(tip.radius == 0.003 && abs(tip.position.z-(toolNode.simdWorldPosition.z-0.185))<0.0001,"actual held brush points its bristles along the palm ray")
  check(paintTools.brushTip(.right) == nil,"other hand cannot paint with this brush")
  let oldDepth = tip.position.z
  for i in 7...20 { paintTools.update(hand:.left,generation:1,fist:true,open:false,ray:rayA,distance:0.85,
     orientation:simd_quatf(),blocked:false,ready:true,at:Double(i)*0.04) }
  check(paintTools.brushTip(.left)!.position.z < oldDepth-0.2,"extending the hand moves brush tip toward wall")
  for i in 21...22 { paintTools.update(hand:.left,generation:1,fist:false,open:true,ray:rayA,distance:0.85,
     orientation:simd_quatf(),blocked:false,ready:true,at:Double(i)*0.04) }
  check(paintTools.brushTip(.left) == nil,"release countdown disables brush contact before the object drops")
  paintTools.cancel()
  let savedTools = paintTools.savedState()
  toolNode.position = .zero;paintTools.restore(savedTools)
  check(paintTools.savedState() == savedTools,"prop save and restore preserve local pose under translated room")
  let savedRoom = h.props.savedState()
  h.props.reset();h.props.restore(savedRoom)
  check(h.props.savedState() == savedRoom,"all sixteen room objects restore their transforms and motion state")
  print("PASS: \(count) production graffiti room bounds, free painting space, prop budget and material checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-room-') as directory:
    script = Path(directory)/'room.swift'
    script.write_text(shim.replace('final class Harness {', props_class + '\nfinal class Harness {') + '\n'.join(method(name) for name in ('material', 'box', 'buildRoomDecor', 'buildLegs', 'buildCan', 'updateRoomMood', 'paintColor', 'applyRoomSettings')) + tests, encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/GraffitiState.swift', root/'HandARBrowser/GraffitiAudio.swift', root/'HandARBrowser/GraffitiPhysics.swift', root/'HandARBrowser/GraffitiRoomSave.swift', script])

assert 'textureWidth: 4096' in source
assert 'sculptureMaterial.diffuse.contents = colors[colorIndex].1' in source
assert 't < GraffitiRoomLayout.maximumPaintDistance' in source
