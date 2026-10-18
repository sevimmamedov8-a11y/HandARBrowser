"""Run the production lens-mask draw method against a point rasterizer.

The shim also supports the old even-odd path, so overlapping apertures expose
the original central black lens as a pixel failure, rather than a compile error.
"""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
mask = source[source.index('final class DirectVideoLensMaskView:'):source.index('private extension MainViewController {', source.index('final class DirectVideoLensMaskView:'))]
stubs = r'''
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
class UIView {
 var bounds = CGRect.zero
 func setNeedsDisplay() {}
 func draw(_ rect: CGRect) {}
}
struct UIColor { static let black=UIColor();var cgColor:Int { 1 } }
enum Blend { case clear }
enum Fill { case eoFill }
func inside(_ point: CGPoint, _ oval: CGRect) -> Bool {
 guard oval.width>0,oval.height>0 else { return false }
 let x=(point.x-oval.midX)/(oval.width/2),y=(point.y-oval.midY)/(oval.height/2)
 return x*x+y*y<=1
}
final class Raster {
 var point=CGPoint.zero,alpha=0.0,clip=CGRect.zero,clearing=false
 var stack:[(CGRect,Bool)]=[]
 var path:[Bool]=[]
 func setFillColor(_ color:Int) {}
 func fill(_ rect:CGRect) { if rect.contains(point) { alpha=1 } }
 func saveGState() { stack.append((clip,clearing)) }
 func restoreGState() { let saved=stack.removeLast();clip=saved.0;clearing=saved.1 }
 func clip(to rect:CGRect) { clip=rect }
 func setBlendMode(_ mode:Blend) { clearing=true }
 func fillEllipse(in oval:CGRect) { if clip.contains(point)&&inside(point,oval) { alpha=clearing ? 0 : 1 } }
 func addRect(_ rect:CGRect) { path.append(rect.contains(point)) }
 func addEllipse(in oval:CGRect) { path.append(inside(point,oval)) }
 func drawPath(using mode:Fill) { alpha=path.filter{$0}.count%2==1 ? 1 : 0;path=[] }
}
var raster=Raster()
func UIGraphicsGetCurrentContext() -> Raster? { raster }
let mask=DirectVideoLensMaskView()
mask.bounds=CGRect(x:0,y:0,width:1600,height:720)
var checks=0
for (left,right) in [
 (CGRect(x:210,y:2,width:700,height:700),CGRect(x:690,y:2,width:700,height:700)),
 (CGRect(x:90,y:20,width:660,height:660),CGRect(x:850,y:20,width:660,height:660)),
 (CGRect(x:250,y:0,width:820,height:720),CGRect(x:790,y:15,width:600,height:660))
] {
 mask.leftCircle=left;mask.rightCircle=right
 for x in stride(from:5,through:1595,by:10) {
  for y in stride(from:5,through:715,by:10) {
   raster=Raster();raster.point=CGPoint(x:x,y:y)
   mask.draw(mask.bounds)
   let expected=inside(raster.point,x<800 ? left : right) ? 0.0 : 1.0
   precondition(raster.alpha==expected,"mask overlap or opposite-eye leakage at \(x),\(y)")
   checks+=1
  }
 }
}
print("PASS: \(checks) production lens-mask pixels, overlapping circles and eye isolation")
'''
with tempfile.TemporaryDirectory(prefix='handar-mask-') as directory:
    script=Path(directory)/'mask.swift'
    # Declarations precede the executable tests (the final code uses the class).
    split=stubs.index('let mask=DirectVideoLensMaskView()')
    script.write_text(stubs[:split]+mask+stubs[split:],encoding='utf-8')
    run_swift_sources([script])
