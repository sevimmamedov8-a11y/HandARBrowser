"""Execute the exact pure Swift homography implementation on a Swift-capable host."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
r=Path(__file__).resolve().parent.parent
source=(r/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
start=source.index('struct CinemaScreenHomography {')
end=source.index('private final class WeakScriptMessageHandler:',start)
tests='''
let unit = [SIMD2<Double>(0,0),SIMD2<Double>(1,0),SIMD2<Double>(1,1),SIMD2<Double>(0,1)]
let quads = [
 [SIMD2<Double>(30,40),SIMD2<Double>(630,40),SIMD2<Double>(630,380),SIMD2<Double>(30,380)],
 [SIMD2<Double>(50,80),SIMD2<Double>(610,120),SIMD2<Double>(530,420),SIMD2<Double>(110,350)],
 [SIMD2<Double>(-100,10),SIMD2<Double>(480,-20),SIMD2<Double>(560,410),SIMD2<Double>(-20,380)]
]
func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
 return abs(a.x-b.x)<0.000001 && abs(a.y-b.y)<0.000001
}
for quad in quads {
 let mapping = CinemaScreenHomography(corners:quad)!
 for i in 0..<4 { precondition(close(mapping.map(unit[i])!,quad[i])) }
 for uv in [SIMD2<Double>(0.5,0.5),SIMD2<Double>(0.1,0.8),SIMD2<Double>(0.9,0.2)] {
  precondition(close(mapping.unmap(mapping.map(uv)!)!,uv))
 }
}
precondition(CinemaScreenHomography(corners:[]) == nil)
precondition(CinemaScreenHomography(corners:Array(repeating:SIMD2<Double>(1,1),count:4)) == nil)
precondition(CinemaScreenHomography(corners:[SIMD2<Double>(.infinity,0),unit[1],unit[2],unit[3]]) == nil)
print("PASS: 24 projection corner/roundtrip/degeneracy checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-projection-') as directory:
    script=Path(directory)/'projection.swift'
    script.write_text(source[start:end]+tests,encoding='utf-8')
    run_swift_sources([script])
