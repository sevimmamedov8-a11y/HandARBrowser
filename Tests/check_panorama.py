"""Offline asset integrity and production spherical projection, without Apple SDKs."""
from pathlib import Path
import hashlib
import json
import struct
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
assets = root / 'HandARBrowser/Panoramas'
catalog = json.loads((assets / 'catalog.json').read_text(encoding='utf-8'))
assert catalog and len({p['id'] for p in catalog}) == len(catalog)

def jpeg_dimensions(data):
    assert data[:2] == b'\xff\xd8'
    offset = 2
    while offset < len(data):
        assert data[offset] == 255
        while data[offset] == 255:
            offset += 1
        marker = data[offset]
        offset += 1
        length = struct.unpack('>H', data[offset:offset+2])[0]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack('>HH', data[offset+3:offset+7])
            return w, h
        offset += length
    raise AssertionError('Missing JPEG dimensions')

for asset in catalog:
    path = assets / asset['filename']
    assert path.parent == assets and path.is_file()
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == asset['sha256'], 'Asset changed: review attribution and checksum'
    assert jpeg_dimensions(data) == (asset['width'], asset['height']) == (4000, 2000)
    assert all(asset[k] for k in ('author', 'license', 'sourceURL', 'licenseURL'))
    assert 0 <= asset['focusU'] <= 1
    assert asset['author'] == 'Levon Avagyan' and asset['license'] == 'CC BY-SA 3.0'
    # 2:1 only checks file integrity; spherical content was also visually inspected.
    assert asset['id'] == 'burj-khalifa-night', 'New places require source/content review'

source = (root / 'HandARBrowser/OfflinePanorama.swift').read_text(encoding='utf-8')
projection = source[source.index('enum PanoramaProjection'):source.index('final class OfflinePanorama')]
tests = r'''
var count = 0
func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
    abs(a.x-b.x) < 0.0001 && abs(a.y-b.y) < 0.0001 && abs(a.z-b.z) < 0.0001
}
let focus = 0.32
check(close(PanoramaProjection.direction(u:focus,v:0.5,focusU:focus), SIMD3(0,0,-1)), "landmark ahead")
check(close(PanoramaProjection.direction(u:focus+0.25,v:0.5,focusU:focus), SIMD3(1,0,0)), "image right stays right, not mirrored")
check(close(PanoramaProjection.direction(u:focus-0.25,v:0.5,focusU:focus), SIMD3(-1,0,0)), "image left stays left")
for i in 0...48 {
    let v = Double(i)/48
    check(close(PanoramaProjection.direction(u:0,v:v,focusU:focus), PanoramaProjection.direction(u:1,v:v,focusU:focus)), "closed seam at every latitude")
}
for i in 0...96 {
    let u = Double(i)/96
    check(close(PanoramaProjection.direction(u:u,v:0,focusU:focus), SIMD3(0,1,0)), "sky at zenith")
    check(close(PanoramaProjection.direction(u:u,v:1,focusU:focus), SIMD3(0,-1,0)), "ground at nadir")
    let p = PanoramaProjection.direction(u:u,v:0.3,focusU:focus)
    check(abs(p.x*p.x+p.y*p.y+p.z*p.z-1)<0.0001, "constant sphere radius")
}
check(PanoramaProjection.yaw(forward:SIMD3(0,0,-1)) == 0,"initial heading")
check(abs(PanoramaProjection.yaw(forward:SIMD3(1,0,0)) + .pi/2)<0.0001,"right recenter")
check(PanoramaProjection.yaw(forward:SIMD3(0,1,0),fallback:1.5)==1.5,"looking straight up keeps heading")
check(PanoramaProjection.yaw(forward:SIMD3(.nan,0,0),fallback:1.5)==1.5,"invalid pose keeps heading")
print("PASS: \(count) panorama projection checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-panorama-') as directory:
    script = Path(directory) / 'main.swift'
    script.write_text('import Foundation\n' + projection + tests, encoding='utf-8')
    run_swift_sources([script])

main = (root / 'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
project = (root / 'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
assert 'path = Panoramas; sourceTree = "<group>"' in project
assert project.count('FA9000000000000000000003 /* Panoramas in Resources */') == 2
assert project.count('FA9000000000000000000001 /* OfflinePanorama.swift in Sources */') == 2
assert 'panoramaActive ? false' in main
assert 'let handMaskActive = !panoramaActive &&' in main
assert 'panorama.followPosition(head: headNode)' in main
assert 'root.simdWorldPosition = head.simdWorldPosition' in source
assert 'self.generation == token' in source
assert 'sphere.geometry = nil' in source
assert 'URLSession' not in source and 'https://' not in source
assert 'data-id="travel"' in main and 'case "panorama-burj":' in main
assert 'свободный оригинал полной панорамы 360° не найден' in main
print('PASS: offline JPEG, checksum, attribution, resource packaging and routing guards')
