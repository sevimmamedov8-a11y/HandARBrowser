"""Exercise actual sample construction with deterministic Vision observations."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root=Path(__file__).resolve().parent.parent
source=(root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
hand_sample=source[source.index('struct HandSample {'):source.index('/// Луч в мировых координатах.')]
state=source[source.index('    private struct HandState {'):source.index('    private var leftState = HandState()')]
sample=source[source.index('    private func sample(_ observation:'):source.index('\n}\n\n@inline(__always)',source.index('    private func sample(_ observation:'))]
helpers=source[source.index('@inline(__always)\nprivate func smooth'):source.index('// MARK: - Ввод в страницу')]
stubs='''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
final class VNHumanHandPoseObservation {
 enum JointName: CaseIterable { case wrist,thumbCMC,thumbMP,thumbIP,thumbTip,indexMCP,indexPIP,indexDIP,indexTip,middleMCP,middlePIP,middleDIP,middleTip,ringMCP,ringPIP,ringDIP,ringTip,littleMCP,littlePIP,littleDIP,littleTip }
 enum Group { case all }
 struct Point { let location: CGPoint; var confidence: Float = 0.95 }
 var points: [JointName: Point] = [:]
 func recognizedPoints(_ group: Group) throws -> [JointName: Point] { points }
}
'''
tests='''
extension HandTracker {
 func exercise() {
  typealias Joint = VNHumanHandPoseObservation.JointName
  let observation = VNHumanHandPoseObservation()
  func set(_ joint: Joint, _ x: Double, _ y: Double) {
   observation.points[joint] = .init(location:CGPoint(x:x,y:y))
  }
  set(.wrist,0.5,0.2);set(.indexMCP,0.43,0.5);set(.middleMCP,0.5,0.52)
  set(.ringMCP,0.57,0.5);set(.littleMCP,0.63,0.48)
  set(.thumbCMC,0.34,0.3);set(.thumbMP,0.3,0.4);set(.thumbIP,0.28,0.48)
  set(.indexPIP,0.43,0.66);set(.indexDIP,0.39,0.65)
  for (mcp,pip,dip,tip,x) in [(Joint.middleMCP,Joint.middlePIP,Joint.middleDIP,Joint.middleTip,0.5),
       (.ringMCP,.ringPIP,.ringDIP,.ringTip,0.57),(.littleMCP,.littlePIP,.littleDIP,.littleTip,0.63)] {
   _ = mcp;set(pip,x,0.65);set(dip,x+0.04,0.58);set(tip,x+0.02,0.4)
  }
  var state = HandState(), time = 0.0, output: HandSample?
  func frames(_ count: Int, index: CGPoint, thumb: CGPoint, confidence: Float = 0.95) {
   set(.indexTip,Double(index.x),Double(index.y));set(.thumbTip,Double(thumb.x),Double(thumb.y))
   observation.points[.thumbTip]?.confidence=confidence;observation.points[.indexTip]?.confidence=confidence
   set(.indexDIP,index.y > 0.8 ? 0.43 : 0.39,index.y > 0.8 ? 0.76 : 0.65)
   for _ in 0..<count {
    time += 1.0/30
    output = sample(observation,side:.right,state:&state,size:SIMD2(1000,750),at:time)
   }
  }
  frames(6,index:CGPoint(x:0.43,y:0.85),thumb:CGPoint(x:0.28,y:0.56))
  precondition(output?.clickOpenConfirmed == true,"visible extended index arms the pinch")
  frames(6,index:CGPoint(x:0.36,y:0.6),thumb:CGPoint(x:0.36,y:0.6))
  precondition(output?.clickPinch == true && output?.isFist == false,"natural curled-index pinch must not grab")
  let pressedGeneration = output!.generation, pressedPoint = output!.indexTip
  frames(12,index:CGPoint(x:0.35,y:0.6),thumb:CGPoint(x:0.35,y:0.6))
  precondition(output?.clickPinch == true && output?.generation == pressedGeneration)
  precondition(output?.indexTip == pressedPoint,"finger articulation cannot move captured pointer")
  // The index PIP may disappear while the two tips and palm remain confident.
  observation.points.removeValue(forKey:.indexPIP)
  frames(2,index:CGPoint(x:0.35,y:0.6),thumb:CGPoint(x:0.35,y:0.6))
  precondition(output?.clickPinch == true && output?.generation == pressedGeneration)
  precondition(output?.maskJoints[.indexPIP] == nil,"cached visual joints cannot cut the mask")
  frames(3,index:CGPoint(x:0.43,y:0.85),thumb:CGPoint(x:0.28,y:0.56))
  precondition(output?.clickPinch == false && output?.clickOpenConfirmed == true)
  precondition(output?.generation == pressedGeneration,"release must not be mistaken for cancellation")
  precondition(output?.indexTip == pressedPoint,"confirmed release stays over the original button")
  frames(1,index:CGPoint(x:0.43,y:0.85),thumb:CGPoint(x:0.28,y:0.56))
  precondition(output!.indexTip != pressedPoint,"ordinary hover resumes")
  // Actual folded fist with touching thumb/index still grabs the panel.
  set(.indexPIP,0.43,0.66)
  frames(6,index:CGPoint(x:0.44,y:0.37),thumb:CGPoint(x:0.44,y:0.38))
  precondition(output?.isFist == true && output?.clickPinch == false)
  state.reset()
  frames(6,index:CGPoint(x:0.36,y:0.6),thumb:CGPoint(x:0.36,y:0.6))
  precondition(output?.clickPinch == false,"closed reacquisition cannot click")
  frames(6,index:CGPoint(x:0.43,y:0.85),thumb:CGPoint(x:0.28,y:0.56))
  frames(6,index:CGPoint(x:0.36,y:0.6),thumb:CGPoint(x:0.36,y:0.6))
  precondition(output?.clickPinch == true)
  observation.points[.thumbTip]?.confidence = 0.1
  time += 1.0/30
  output = sample(observation,side:.right,state:&state,size:SIMD2(1000,750),at:time)
  precondition(output?.clickPinch == false && output!.generation > pressedGeneration,"uncertain contact cancels")
  // The wide camera makes fingertip evidence less confident. Fresh .60
  // points remain usable; low-confidence or absent tips must still cancel.
  state.reset()
  frames(6,index:CGPoint(x:0.43,y:0.85),thumb:CGPoint(x:0.28,y:0.56),confidence:0.60)
  frames(6,index:CGPoint(x:0.36,y:0.6),thumb:CGPoint(x:0.36,y:0.6),confidence:0.60)
  precondition(output?.clickPinch == true,"fresh moderate-confidence tips can complete a pinch")
  observation.points.removeValue(forKey:.thumbTip)
  time += 1.0/30
  output = sample(observation,side:.right,state:&state,size:SIMD2(1000,750),at:time)
  precondition(output?.clickPinch == false,"missing thumb cannot maintain a pinch from cached joints")
  precondition(output?.maskJoints[.indexTip] != nil,"dwell still has a fresh index when the thumb disappears")
  print("PASS: 17 actual HandTracker sample integration checks")
 }
}
@main struct TrackerTests { static func main() { HandTracker().exercise() } }
'''
with tempfile.TemporaryDirectory(prefix='handar-tracker-') as directory:
    script=Path(directory)/'tracker.swift'
    script.write_text(stubs+hand_sample+'\nfinal class HandTracker {\n'+state+sample+'\n}\n'+helpers+tests,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift',script])
