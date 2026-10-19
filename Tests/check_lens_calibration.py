"""Execute production calibration controls with recording UI stand-ins."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
root=Path(__file__).resolve().parent.parent
source=(root/'HandARBrowser/LensCalibration.swift').read_text(encoding='utf-8')
methods=source[source.index('    private func value()'):source.index('    override func draw(')].replace('private func','func')
stubs=r'''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
var saves=0
struct VRProfile {
 var lensSeparationMM:Float=63,lensVerticalOffsetMM:Float=0,eyeToScreenMM:Float=42,k1:Float=0,k2:Float=0
 var screenHorizontalOffsetMM:Float?,rightEyeVerticalOffsetMM:Float?
 func save(){saves+=1}
}
class View {var center=CGPoint.zero,isHidden=false,frame=CGRect.zero}
final class Label {var text:String?}
final class Progress {var progress:Float=0}
enum Events {case touchUpInside}
final class Button:View {var isHighlighted=false;var action:(()->Void)?;func sendActions(for event:Events){action?()}}
final class Harness {
 var profile=VRProfile(),parameter=0,gate=ReleaseClickGate<Int>()
 let bounds=CGRect(x:0,y:0,width:844,height:390)
 let names=["Lenses","Horizontal","Vertical","Vertical match","Depth","k1","k2"]
 let labels=[Label(),Label()],progress=[Progress(),Progress()],cursors=[View(),View()]
 var buttons:[Button]=[]
 var onChange:((VRProfile)->Void)?,onFinish:(()->Void)?,onInteraction:(()->Void)?
 func setNeedsDisplay(){}
 init(){
  for eye in 0..<2 {for action in 0..<5 {
   let b=Button();b.frame=CGRect(x:Double(eye)*422+20+Double(action)*65,y:334,width:55,height:40)
   b.action={ [weak self] in self?.perform(action) };buttons.append(b)
  }}
 }
'''
tests=r'''
}
@main struct Tests {
 static func main(){
  var count=0,changes=0,clicks=0,finished=0
  func check(_ value:Bool,_ message:String){count+=1;precondition(value,message)}
  let h=Harness();h.onChange={_ in changes+=1};h.onInteraction={clicks+=1};h.onFinish={finished+=1}
  let plus=CGPoint(x:177,y:354),minus=CGPoint(x:112,y:354)
  for tick in 0...80 {h.updatePointer(plus,down:false,dwell:true,time:Double(tick)*0.05)}
  check(changes==1 && clicks==1 && h.profile.lensSeparationMM==63.25,"holding plus performs exactly one adjustment and confirmation")
  check(h.cursors.allSatisfy{!$0.isHidden},"both eyes show the same calibration pointer")
  h.updatePointer(nil,down:false,dwell:true,time:4.1)
  check(h.cursors.allSatisfy{$0.isHidden} && h.progress.allSatisfy{$0.progress==0},"tracking loss cancels pointer and progress")
  for tick in 0...6 {h.updatePointer(plus,down:false,dwell:true,time:5+Double(tick)*0.05)}
  h.updatePointer(nil,down:false,dwell:true,time:5.4)
  check(changes==1,"unfinished dwell cannot modify calibration on tracking loss")
  for tick in 0...24 {h.updatePointer(CGPoint(x:plus.x+422,y:plus.y),down:false,dwell:true,time:6+Double(tick)*0.05)}
  check(changes==2 && h.profile.lensSeparationMM==63.5,"right-eye control addresses the same adjustment exactly once")
  h.cancelInteraction()
  h.updatePointer(minus,down:true,allowBegin:false,dwell:false,time:8)
  h.updatePointer(minus,down:false,allowBegin:false,dwell:false,time:8.1)
  check(changes==2,"a held pinch appearing after loss cannot adjust calibration")
  h.updatePointer(minus,down:true,dwell:false,time:8.2)
  check(changes==2,"pinch press alone does not adjust")
  h.updatePointer(minus,down:false,dwell:false,time:8.3)
  h.updatePointer(minus,down:false,dwell:false,time:8.4)
  check(changes==3 && h.profile.lensSeparationMM==63.25,"one confirmed pinch release adjusts once")
  h.perform(3);h.perform(2)
  check(h.parameter==1 && abs((h.profile.screenHorizontalOffsetMM ?? -1)-0.1)<1e-6,"horizontal calibration is wired to the physical phone offset")
  h.perform(3);h.perform(1)
  check(h.parameter==2 && abs(h.profile.lensVerticalOffsetMM+0.1)<1e-6,"shared vertical offset is adjustable")
  h.perform(3);h.perform(2)
  check(h.parameter==3 && abs((h.profile.rightEyeVerticalOffsetMM ?? -1)-0.05)<1e-6,"fine vertical matching uses 0.05 mm steps")
  h.parameter=0;h.profile.lensSeparationMM=76;h.perform(2)
  check(h.profile.lensSeparationMM==76,"lens distance is bounded")
  h.parameter=4;h.profile.eyeToScreenMM=30;h.perform(1)
  check(h.profile.eyeToScreenMM==30,"screen distance is bounded")
  h.parameter=5;h.profile.k1=0.8;h.perform(2)
  check(h.profile.k1==0.8,"radial k1 is bounded")
  h.parameter=6;h.profile.k2 = -0.2;h.perform(1)
  check(h.profile.k2 == -0.2,"radial k2 is bounded")
  h.parameter=0;h.perform(0)
  check(h.parameter==6,"parameter navigation wraps")
  let before=saves;h.perform(4)
  check(finished==1 && saves==before+1,"Done saves the profile and closes through its callback")
  check(h.labels[0].text==h.labels[1].text,"instructions and values match in both eyes")
  print("PASS: \(count) actual calibration control, dwell, pinch, loss, persistence and bounds checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-calibration-') as directory:
    path=Path(directory)/'calibration.swift'
    path.write_text(stubs+methods+tests,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift',path])
