"""Execute production occlusion and open-palm swipe state machines."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root=Path(__file__).resolve().parent.parent
tests=r'''
import Foundation
@main struct Tests {
 static func main() {
  var checks=0
  func check(_ value:Bool, line:Int = #line) { precondition(value,"failed check at line \(line), after \(checks) checks");checks+=1 }
  var fist=OccludedFistGesture()
  for i in 0..<15 { check(!fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:Double(i)/30)) }
  check(!fist.update(visibleTips:4,palmReliable:true,pinchEngaged:false,at:0.5))
  // Gradually disappearing fingers retain the same skeleton's recent evidence.
  check(!fist.update(visibleTips:3,palmReliable:true,pinchEngaged:false,at:0.53))
  check(!fist.update(visibleTips:2,palmReliable:true,pinchEngaged:false,at:0.56))
  check(!fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:0.6))
  check(!fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:0.7))
  check(fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:0.77))
  for i in 0..<60 { check(fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:0.8+Double(i)/30)) }
  check(!fist.update(visibleTips:0,palmReliable:false,pinchEngaged:false,at:2.81))
  check(!fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:2.84))
  fist.reset()
  _=fist.update(visibleTips:4,palmReliable:true,pinchEngaged:false,at:3)
  for i in 1...9 { check(!fist.update(visibleTips:0,palmReliable:true,pinchEngaged:true,at:3+Double(i)/30)) }
  for i in 10...18 { check(!fist.update(visibleTips:1,palmReliable:true,pinchEngaged:false,hiddenAllowed:false,at:3+Double(i)/30)) }
  // Freshness gap and backwards timestamps invalidate old open-hand evidence.
  check(!fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:5))
  check(!fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:4))
  check(!fist.update(visibleTips:0,palmReliable:true,pinchEngaged:false,at:.nan))

  for hand in [TrackedHand.left,.right] { for direction in [-1.0,1.0] {
   var swipe=OpenPalmSwipeGesture(),events:[Int]=[]
   for i in 0...8 {
    if let event=swipe.update(hand:hand,point:SIMD2(0.5+direction*Double(i)*0.02,0.5),at:Double(i)/30) {events.append(event)}
   }
   check(events == [direction<0 ? -1:1]);check(swipe.isMoving)
   for i in 9...50 { check(swipe.update(hand:hand,point:SIMD2(0.5+direction*0.16,0.5),at:Double(i)/30)==nil) }
   check(!swipe.isMoving) // stationary palm rearms after cooldown
   var reverse:[Int]=[]
   for i in 1...8 {
    if let event=swipe.update(hand:hand,point:SIMD2(0.5+direction*0.16-direction*Double(i)*0.02,0.5),at:Double(50+i)/30) {reverse.append(event)}
   }
   check(reverse == [direction<0 ? 1:-1])
  }}
  var swipe=OpenPalmSwipeGesture()
  for i in 0...30 { check(swipe.update(hand:.left,point:SIMD2(0.5,0.2+Double(i)*0.01),at:Double(i)/30)==nil) }
  swipe.reset()
  for i in 0...90 { check(swipe.update(hand:.left,point:SIMD2(0.3+Double(i)*0.002,0.5),at:Double(i)/30)==nil) }
  swipe.reset()
  _=swipe.update(hand:.left,point:SIMD2(0.3,0.5),at:0)
  check(swipe.update(hand:.right,point:SIMD2(0.8,0.5),at:0.15)==nil)
  check(swipe.update(hand:.right,point:SIMD2(0.95,0.5),at:0.8)==nil)
  check(swipe.update(hand:nil,point:nil,at:0.83)==nil && !swipe.isMoving)
  print("PASS: \(checks) hidden-finger fist and open-palm swipe lifecycle checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-menu-gestures-') as directory:
    script=Path(directory)/'test.swift'
    script.write_text(tests,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift',script])
