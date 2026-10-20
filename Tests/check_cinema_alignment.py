"""Execute production entrance alignment with a minimal transform shim."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root=Path(__file__).resolve().parent.parent
hall=(root/'HandARBrowser/CinemaHall.swift').read_text(encoding='utf-8')
controller=(root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
def method(name):
    begin=hall.index('    '+('private ' if name=='updateScreenTransform' else '')+'func '+name)
    end=hall.index('{',begin)+1
    depth=1
    while depth:
        depth+=(hall[end]=='{')-(hall[end]=='}');end+=1
    return hall[begin:end]
layout=hall[hall.index('enum CinemaHallLayout {'):hall.index('/// Blue tiered auditorium')]
shim=r'''
import Foundation
struct Matrix {
 var columns:(SIMD4<Float>,SIMD4<Float>,SIMD4<Float>,SIMD4<Float>)
}
let matrix_identity_float4x4=Matrix(columns:(SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,1,0),SIMD4(0,0,0,1)))
func simd_length(_ value:SIMD3<Float>)->Float {sqrt(value.x*value.x+value.y*value.y+value.z*value.z)}
struct simd_quatf {
 let forward:SIMD3<Float>
 init(from:SIMD3<Float>,to:SIMD3<Float>) {forward=to}
}
func simd_mul(_ a:Matrix,_ b:Matrix)->Matrix {
 func column(_ v:SIMD4<Float>)->SIMD4<Float> {a.columns.0*v.x+a.columns.1*v.y+a.columns.2*v.z+a.columns.3*v.w}
 return Matrix(columns:(column(b.columns.0),column(b.columns.1),column(b.columns.2),column(b.columns.3)))
}
final class Node {
 var simdPosition=SIMD3<Float>.zero
 var simdOrientation=simd_quatf(from:SIMD3(0,0,-1),to:SIMD3(0,0,-1))
 var simdTransform:Matrix {
  let f=simdOrientation.forward,p=simdPosition
  return Matrix(columns:(SIMD4(-f.z,0,f.x,0),SIMD4(0,1,0,0),SIMD4(-f.x,-f.y,-f.z,0),SIMD4(p.x,p.y,p.z,1)))
 }
}
final class Hall {
 static let screenCenterHeight=CinemaHallLayout.screenCenterHeight,screenDistance=CinemaHallLayout.screenDistance
 let root=Node()
 var screenWorldTransform=matrix_identity_float4x4
'''
tests=r'''
}
let hall=Hall()
var checks=0
func check(_ value:Bool){precondition(value);checks+=1}
for angle in stride(from:Float(0),to:Float(6.3),by:0.13) {
 for position in [SIMD3<Float>(0,0,0),SIMD3<Float>(1,1.6,-4),SIMD3<Float>(-2,0.8,3)] {
  let forward=SIMD3<Float>(sin(angle),0,-cos(angle))
  hall.alignViewer(origin:position,forward:forward*0.7+SIMD3(0,0.6,0))
  let screen=hall.screenWorldTransform.columns.3
  let expected=position+forward*Hall.screenDistance
  check(abs(screen.x-expected.x)<0.0001 && abs(screen.z-expected.z)<0.0001)
  check(abs(screen.y-position.y)<0.0001) // straight ahead at camera height
  let before=screen
  hall.alignViewer(origin:position,forward:forward)
  let after=hall.screenWorldTransform.columns.3
  check(simd_length(SIMD3(after.x-before.x,after.y-before.y,after.z-before.z))<0.0001)
 }
}
hall.alignViewer(origin:SIMD3(0,1,0),forward:SIMD3(0,1,0))
check(hall.screenWorldTransform.columns.3.z == -Hall.screenDistance)
check(hall.screenWorldTransform.columns.3.y == 1)
hall.alignViewer(origin:SIMD3(0,1,0),forward:SIMD3(.nan,0,0))
check(hall.screenWorldTransform.columns.3.z == -Hall.screenDistance)
print("PASS: \(checks) actual cinema entrance heading, height and degenerate-pose checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-alignment-') as directory:
    script=Path(directory)/'alignment.swift'
    script.write_text(layout+shim+method('alignViewer')+'\n'+method('updateScreenTransform')+tests,encoding='utf-8')
    run_swift_sources([script])
assert 'self.cinemaActive, self.cinemaNeedsAlignment' in controller
assert 'headNode.simdTransform=tracking.headTransform(frame)' in controller
assert 'cinemaNeedsAlignment = false' in controller
assert 'moveViewer' not in hall and 'stepForwardButton' not in hall
print('PASS: fresh-camera alignment integration and no added locomotion')
