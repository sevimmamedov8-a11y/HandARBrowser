"""Exercise production raster painting/erasing on macOS CoreGraphics in CI."""
from pathlib import Path
import sys
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/GraffitiStudio.swift').read_text(encoding='utf-8')
canvas = source[source.index('private final class GraffitiCanvas {'):source.index('final class GraffitiStudio {')]
canvas = canvas.replace('private final class GraffitiCanvas', 'final class GraffitiCanvas')
assert 'guard !erasing else { return nil }' in source, 'eraser must not allocate blank home canvases'
assert 'hardEdge: preferences.hardEdge, erasing: erasing' in source
assert 'audio.setSpraying(!erasing)' in source and 'audio.setErasing(erasing)' in source
assert 'undo.append((hit.canvas.id, image))' in source
print('PASS: eraser routing, undo snapshot, sound selection and existing-wall-only erasing')
if sys.platform != 'darwin':
    print('SKIP: real raster pixel checks require macOS CoreGraphics; run in GitHub macOS workflow')
    raise SystemExit(0)

shim = r'''
import Foundation
import CoreGraphics
import CoreFoundation
struct UIColor {
 let cgColor: CGColor
 init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) { cgColor = CGColor(srgbRed:r,green:g,blue:b,alpha:a) }
 func withAlphaComponent(_ a: CGFloat) -> Self { Self(cgColor:cgColor.copy(alpha:a)!) }
 private init(cgColor:CGColor) { self.cgColor = cgColor }
}
struct UIImage { let cgImage: CGImage }
final class Property { enum Filter { case linear }; var contents: Any?, mipFilter = Filter.linear }
final class SCNMaterial {
 enum Lighting { case constant }
 var lightingModel = Lighting.constant, isDoubleSided = false, writesToDepthBuffer = false
 let diffuse = Property()
}
final class SCNPlane {
 var firstMaterial: SCNMaterial?
 init(width:CGFloat,height:CGFloat) {}
}
final class SCNNode {
 let geometry: SCNPlane?
 init(geometry:SCNPlane?) { self.geometry = geometry }
}
'''
tests = r'''
import Foundation
import CoreGraphics
@main struct Tests {
 static func main() {
  var count = 0
  func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1 }
  func pixel(_ image:CGImage, _ x:Int=128,_ y:Int=128) -> [UInt8] {
   let bytes = image.dataProvider!.data! as Data
   let offset = y*image.bytesPerRow+x*4
   return Array(bytes[offset..<offset+4])
  }
  for base in [UIColor(0.8,0.8,0.8), UIColor(0,0,0,0)] {
   let canvas = GraffitiCanvas(size:SIMD2(2,2),base:base,textureWidth:256)
   let original = canvas.snapshot()!
   canvas.spray(points:[.zero,SIMD2(0.5,0)],radius:0.2,color:UIColor(1,0,0),clip:nil,flow:1,hardEdge:true)
   let painted = canvas.snapshot()!
   check(pixel(painted) != pixel(original),"test paints visible pixels")
   canvas.spray(points:[.zero],radius:0.14,color:UIColor(1,0,0),clip:nil,flow:1,hardEdge:true,erasing:true)
   let erased = canvas.snapshot()!
   check(pixel(erased) == pixel(original),"eraser restores original wall RGBA including full transparency")
   check(pixel(erased,192) == pixel(painted,192),"eraser preserves paint outside its radius")
   check(canvas.dirty,"eraser marks bitmap for GPU upload")
   canvas.upload();check(!canvas.dirty,"erased result uploads")
   canvas.restore(painted);check(pixel(canvas.snapshot()!) == pixel(painted),"undo restores paint erased by stroke")
   let clip: [SIMD2<Double>] = [SIMD2(0,-1),SIMD2(1,-1),SIMD2(1,1),SIMD2(0,1)]
   canvas.spray(points:[.zero],radius:0.2,color:UIColor(1,0,0),clip:clip,flow:1,hardEdge:true,erasing:true)
   check(pixel(canvas.snapshot()!,135) == pixel(original,135),"eraser works inside tracked wall boundary")
   check(pixel(canvas.snapshot()!,121) == pixel(painted,121),"eraser cannot cross tracked wall boundary")
  }
  print("PASS: \(count) production CoreGraphics paint, eraser, transparency, clipping and undo checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-eraser-') as directory:
    model = Path(directory)/'canvas.swift'
    model.write_text(shim+canvas, encoding='utf-8')
    test = Path(directory)/'tests.swift'
    test.write_text(tests, encoding='utf-8')
    run_swift_sources([model,test])
