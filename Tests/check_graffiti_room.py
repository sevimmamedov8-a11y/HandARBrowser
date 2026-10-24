"""Build production room props with geometry-recording SceneKit stand-ins."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/GraffitiStudio.swift').read_text(encoding='utf-8')

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
struct UIColor: Hashable {
 var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
 init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { self.red=red;self.green=green;self.blue=blue;self.alpha=alpha }
 init(white: CGFloat, alpha: CGFloat) { self.init(red:white,green:white,blue:white,alpha:alpha) }
 static let black = UIColor(white: 0, alpha: 1)
}
enum Lighting { case constant }
final class Property { var contents: Any? }
final class SCNMaterial {
 var lightingModel = Lighting.constant, isDoubleSided = false
 let diffuse = Property()
}
class Geometry { var firstMaterial: SCNMaterial?; var halfSize = SCNVector3.zero }
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
 var geometry: Geometry?, position = SCNVector3.zero, eulerAngles = SCNVector3.zero
 var childNodes: [SCNNode] = [], constraints: [Int] = [], animated = false, flattened = false
 init(geometry: Geometry? = nil) { self.geometry = geometry }
 func addChildNode(_ node: SCNNode) { childNodes.append(node) }
 func flattenedClone() -> SCNNode { flattened = true;return self }
 func runAction(_ action: SCNAction) { animated = true }
}
final class CineText: SCNNode {
 var text = "", width: Float = 0
 func setText(_ value: String, color: UIColor) { text = value }
 func fitWidth(_ value: Float) { width = value }
}
final class Harness {
 let room = SCNNode(), sculptureMaterial = SCNMaterial()
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
  check(meshes.count > 50 && meshes.count < 120, "bounded set of room decor meshes")
  check(nodes.filter { $0.animated }.count == 1, "only one slowly animated object")
  check(h.room.childNodes.contains { $0.flattened }, "static decor is merged once")
  let materials = Set(meshes.compactMap { $0.geometry?.firstMaterial }.map { ObjectIdentifier($0) })
  check(materials.count < 20, "static color materials are shared")
  for node in meshes {
   var size = node.geometry!.halfSize
   if abs(node.eulerAngles.x) > 1 { size = SCNVector3(size.x, size.z, size.y) }
   let p = node.position
   check(abs(p.x) + size.x <= GraffitiRoomLayout.span * 0.5 + 0.04 &&
         abs(p.z) + size.z <= GraffitiRoomLayout.span * 0.5 + 0.04, "props fit inside expanded room")
   check(p.y - size.y >= GraffitiRoomLayout.floorY - 0.03 &&
         p.y + size.y <= GraffitiRoomLayout.ceilingY + 0.04, "props meet floor and ceiling")
   check(!(p.z < 0 && abs(p.x) < 3.5 && p.y > GraffitiRoomLayout.floorY + 0.2 && p.y < 1.5),
         "front central painting area remains clear")
   if let cylinder = node.geometry as? SCNCylinder { check(cylinder.radialSegmentCount <= 16, "cans and speakers use small meshes") }
  }
  let sculpture = nodes.first { $0.animated }!
  check(sculpture.geometry?.firstMaterial === h.sculptureMaterial, "selected paint color can update the sculpture without rebuilding it")
  let sign = nodes.compactMap { $0 as? CineText }.first!
  check(sign.text == "HANDAR  /  SPRAY LAB" && sign.position.z > 3 && sign.constraints.isEmpty,
        "studio sign stays attached to the rear wall")
  print("PASS: \(count) production graffiti room bounds, free painting space, prop budget and material checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-room-') as directory:
    script = Path(directory)/'room.swift'
    script.write_text(shim + '\n'.join(method(name) for name in ('material', 'box', 'buildRoomDecor')) + tests, encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/GraffitiState.swift', script])

assert 'textureWidth: 1536' in source
assert 'sculptureMaterial.diffuse.contents = colors[colorIndex].1' in source
assert 't < GraffitiRoomLayout.maximumPaintDistance' in source
