"""Exercise actual pose math and glove lifecycle using SceneKit recording doubles."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
native = [root/'HandARBrowser/VirtualHands.swift', root/'HandARBrowser/HandGesture.swift']
run_swift_sources(native + [root/'HandARBrowser/HandSilhouette.swift', root/'Tests/VirtualHandsTests.swift'])

source = native[0].read_text(encoding='utf-8')
renderer = source[source.index('final class VirtualHands {'):source.rindex('#endif')]
shim = r'''
import Foundation
struct simd_float3x3 { init(columns: (SIMD3<Float>,SIMD3<Float>,SIMD3<Float>)) {} }
struct simd_quatf {
 init() {}
 init(_ basis: simd_float3x3) {}
 init(from: SIMD3<Float>, to: SIMD3<Float>) {}
}
func simd_length(_ v: SIMD3<Float>) -> Float { VirtualHandPose.length(v) }
struct UIColor {
 init(white: CGFloat, alpha: CGFloat) {}
 init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {}
}
final class MaterialProperty { var contents: Any? }
final class SCNMaterial {
 enum Lighting { case lambert }
 var lightingModel = Lighting.lambert
 let diffuse = MaterialProperty(), emission = MaterialProperty()
}
class SCNGeometry { var firstMaterial: SCNMaterial? }
final class SCNBox: SCNGeometry {
 var chamferSegmentCount = 1
 init(width: CGFloat, height: CGFloat, length: CGFloat, chamferRadius: CGFloat) { super.init() }
}
final class SCNSphere: SCNGeometry {
 var segmentCount = 24
 init(radius: CGFloat) { super.init() }
}
final class SCNCapsule: SCNGeometry {
 var radialSegmentCount = 24, capSegmentCount = 12
 init(capRadius: CGFloat, height: CGFloat) { super.init() }
}
final class SCNLight {
 enum Kind { case ambient, directional }
 var type = Kind.ambient, intensity: CGFloat = 1, categoryBitMask = -1, castsShadow = false
}
final class SCNNode {
 var geometry: SCNGeometry?, light: SCNLight?, categoryBitMask = 1, isHidden = false
 var simdPosition = SIMD3<Float>.zero, simdScale = SIMD3<Float>(repeating: 1)
 var simdOrientation = simd_quatf(), simdWorldOrientation = simd_quatf()
 weak var parent: SCNNode?
 var childNodes: [SCNNode] = []
 init(geometry: SCNGeometry? = nil) { self.geometry = geometry }
 func addChildNode(_ node: SCNNode) { node.removeFromParentNode(); childNodes.append(node); node.parent = self }
 func removeFromParentNode() { parent?.childNodes.removeAll { $0 === self }; parent = nil }
}
final class SCNScene { let rootNode = SCNNode() }
'''
tests = r'''
@main struct Test {
 static func main() {
  var checks = 0
  func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
  let hands = VirtualHands(), scene = SCNScene(), head = SCNNode()
  hands.start(in: scene)
  let root = scene.rootNode.childNodes[0], left = root.childNodes[0], right = root.childNodes[1]
  var points = [SIMD3<Float>?](repeating: nil, count: 21)
  points[0] = SIMD3(0,0,-0.5)
  for f in 0..<5 { for j in 0..<4 { points[1+f*4+j] = SIMD3(Float(2-f)*0.025,0.08+Float(j)*0.025,-0.5) } }
  let pose = VirtualHandPose(points: points, camera: .zero)!
  check(left.isHidden && right.isHidden, "start has no ghost hands")
  hands.update(hand: .left, pose: pose, timestamp: 10, at: 10, visible: true)
  check(!left.isHidden && right.isHidden, "left update cannot activate right")
  hands.update(hand: .right, pose: pose, timestamp: 10.04, at: 10.04, visible: true)
  check(!left.isHidden && !right.isHidden, "both hands tracked independently")
  hands.update(hand: .left, pose: pose, timestamp: 10.05, at: 10.05, visible: false)
  check(left.isHidden && !right.isHidden, "drawing suppresses only its glove")
  hands.tick(at: 10.15, ready: true, head: head)
  check(!right.isHidden, "fresh opposite glove stays")
  hands.tick(at: 10.17, ready: true, head: head)
  check(right.isHidden, "watchdog hides stale hand even without a callback")
  hands.update(hand: .right, pose: pose, timestamp: 11, at: 11, visible: true)
  hands.tick(at: 11, ready: false, head: head)
  check(right.isHidden, "camera tracking loss hides gloves")
  hands.update(hand: .right, pose: pose, timestamp: 12, at: 11, visible: true)
  check(right.isHidden, "future timestamp does not bypass watchdog")
  hands.update(hand: .right, pose: pose, timestamp: 12, at: 12, visible: true)
  points[7] = nil
  hands.update(hand: .right, pose: VirtualHandPose(points: points, camera: .zero), timestamp: 12.04, at: 12.04, visible: true)
  check(right.childNodes[7].isHidden && right.childNodes[8].isHidden, "missing DIP hides adjacent finger segments")
  check(!right.childNodes[9].isHidden, "other finger remains visible")
  let palm = right.childNodes[0]
  let expectedWidth = pose.width*1.22*0.78
  check(abs(palm.simdScale.x-expectedWidth)<0.00001 && palm.simdPosition == pose.center,"glove is smaller around unchanged palm")
  let hiddenScale = right.childNodes[7].simdScale
  for _ in 0..<30 { hands.update(hand:.right,pose:VirtualHandPose(points:points,camera:.zero),timestamp:12.04,at:12.04,visible:true) }
  check(right.childNodes[7].simdScale == hiddenScale,"hidden segments do not cumulatively shrink")
  for _ in 0..<100 { hands.update(hand: .right, pose: pose, timestamp: 13, at: 13, visible: true) }
  check(abs(palm.simdScale.x-expectedWidth)<0.00001,"successive frames keep the same scale")
  check(root.childNodes.count == 4 && right.childNodes.count == 18, "fixed scene budget across updates")
  for glove in [left,right] {
   for node in glove.childNodes {
    check(node.categoryBitMask == 512, "only glove lighting category")
    check(node.simdScale.x > 0 && node.simdScale.y > 0 && node.simdScale.z > 0, "no inverted meshes")
   }
  }
  hands.stop(); check(scene.rootNode.childNodes.isEmpty && left.isHidden && right.isHidden, "exit clears nodes and tracking")
  hands.start(in: scene);hands.start(in: scene)
  check(scene.rootNode.childNodes.count == 1, "reentry does not duplicate hands or lights")
  print("PASS: \(checks) production virtual glove lifecycle and bounded scene checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-gloves-') as directory:
    path = Path(directory)/'gloves.swift'
    path.write_text(shim + renderer + tests, encoding='utf-8')
    # Only the portable pose portion is used; renderer above uses the recording doubles.
    pose_file = Path(directory)/'pose.swift'
    pose_file.write_text(source[:source.index('#if canImport')], encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift', pose_file, path])

main = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
pose = main[main.index('    private func virtualHandPose('):main.index('    // MARK: Offline 360')]
assert 'sample.maskJoints' in pose and 'sample.joints' not in pose
assert 'virtualHands.stop()' in main and 'virtualHands.tick(' in main
assert 'graffiti.showsVirtualHand(hand)' in main
project = (root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
assert project.count('/* VirtualHands.swift in Sources */') == 2
print('PASS: fresh-joint routing, lifecycle and Xcode source registration')
