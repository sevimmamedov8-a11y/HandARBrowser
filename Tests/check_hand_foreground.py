"""Exercise production camera uniforms, mask freshness and shader blend branches."""
from pathlib import Path
import json
import re
import subprocess
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')

def method(name):
    start = source.index('    private func ' + name + '(')
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

uniforms = source[source.index('private struct VRUniforms {'):source.index('/// Финальный проход.')].replace('private struct', 'struct')
eligibility = next(line.strip() for line in source.splitlines() if 'let handMaskActive = !panoramaActive' in line)
shim = r'''
import Foundation
var clock = 10.0
func CACurrentMediaTime() -> Double { clock }
struct Profile { var k1: Float = 0, k2: Float = 0, chroma: Float = 0 }
enum Orientation { case landscapeLeft, landscapeRight }
struct EyeFrustum { var left: Float = -0.5, right: Float = 0.5, bottom: Float = -0.3, top: Float = 0.3 }
enum VRLensMath {
 static func lensCenterUV(eye: Int, profile: Profile) -> SIMD2<Float> { SIMD2(0.5, 0.5) }
 static func renderScale(profile: Profile, aspect: Float) -> Float { 1 }
}
struct CameraFrame { var projection: CameraProjection? }
final class Tracking { func projection(for frame: CameraFrame) -> CameraProjection? { frame.projection } }
struct Graffiti { var mode = GraffitiMode.room }
final class Texture {
 var uploads = 0
 func replace(region: Int, mipmapLevel: Int, withBytes: UnsafeRawPointer, bytesPerRow: Int) { uploads += 1 }
}
func MTLRegionMake2D(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Int { width * height }
final class Harness {
 var profile = Profile(), tracking = Tracking(), orientation = Orientation.landscapeRight
 var cameraPassthroughRequested = false, panoramaActive = false, graffitiActive = true
 var graffiti = Graffiti(), handMaskTexture: Texture? = Texture()
 let handMaskLock = NSLock(), handMaskWidth = 2, handMaskHeight = 2
 var pendingHandMaskActive = true, handMaskNeedsUpload = true, handMaskTimestamp = 10.0
 var pendingHandMaskBytes: [UInt8] = [0, 255, 255, 0]
 func currentInterfaceOrientation() -> Orientation { orientation }
 func fullEyeFrustum(eye: Int, aspect: Float) -> EyeFrustum { EyeFrustum() }
'''
tests = r'''
}
@main struct Tests {
 static func main() {
  var count = 0
  func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
  let h = Harness(), size = CGSize(width: 1600, height: 720)
  let projection = CameraProjection(width: 1280, height: 720, fx: 650, fy: 660, cx: 640, cy: 360, rayScale: 1)!
  let frame = CameraFrame(projection: projection)
  for orientation in [Orientation.landscapeLeft, .landscapeRight] {
   h.orientation = orientation
   let u = h.makeUniforms(drawableSize: size, frame: frame, hasCamera: true, handMaskActive: true)
   check(u.passthrough == 0 && u.handMaskEnabled == 1, "hands can sample camera without enabling real background")
   let mapping = h.cameraMapping(for: EyeFrustum(), projection: projection, flipped: orientation == .landscapeLeft)
   check(u.camScaleL == mapping.scale && u.camOffsetL == mapping.offset, "hand-only view gets calibrated mapping")
   check(u.camScaleR == u.camScaleL && u.camOffsetR == u.camOffsetL, "both eyes use same hand image mapping")
  }
  for missingFrame in [false, true] {
   let u = h.makeUniforms(drawableSize: size, frame: missingFrame ? nil : frame, hasCamera: false, handMaskActive: true)
   check(u.handMaskEnabled == 0 && u.passthrough == 0, "no texture cannot sample a camera fallback")
  }
  h.cameraPassthroughRequested = true
  let invalid = h.makeUniforms(drawableSize: size, frame: CameraFrame(projection: nil), hasCamera: true, handMaskActive: true)
  check(invalid.handMaskEnabled == 0 && invalid.passthrough == 0, "invalid projection cannot leak camera pixels")
  let home = h.makeUniforms(drawableSize: size, frame: frame, hasCamera: true)
  check(home.passthrough == 1 && home.handMaskEnabled == 0, "home mode keeps normal camera background")
  check(h.syncHandMaskTexture() && h.handMaskTexture?.uploads == 1, "fresh mask uploads once")
  clock = 10.1
  check(h.syncHandMaskTexture() && h.handMaskTexture?.uploads == 1, "unchanged fresh mask does not upload repeatedly")
  clock = 10.121
  check(!h.syncHandMaskTexture(), "stale mask disappears")
  clock = 9.9
  check(!h.syncHandMaskTexture(), "future mask is rejected")
  clock = 10.04
  h.cameraPassthroughRequested = false
  check(h.handMaskForFrame(), "room allows fresh hands with real background disabled")
  h.graffiti.mode = .home; h.cameraPassthroughRequested = true
  check(!h.handMaskForFrame(), "home does not overlay duplicate foreground")
  h.panoramaActive = true; h.graffitiActive = false
  check(!h.handMaskForFrame(), "panorama keeps hands disabled")
  h.panoramaActive = false
  check(h.handMaskForFrame(), "normal camera browser keeps hands")
  h.cameraPassthroughRequested = false
  check(!h.handMaskForFrame(), "ordinary dark browser preserves previous behavior")
  h.graffitiActive = true; h.graffiti.mode = .room; h.pendingHandMaskActive = false
  check(!h.handMaskForFrame(), "no hand never leaves a camera cutout in room")
  print("PASS: \(count) production hand-foreground mapping, availability and freshness checks")
 }
}
'''

# Evaluate the actual shader compositing block with scalar grayscale samples.
# This tests mask/background branching, not Metal compilation or GPU rendering.
blend = source[source.index('        float3 background ='):source.index('        return float4(color, 1.0);')]
blend = re.sub(r'\b(?:float[234]?|bool)\s+(\w+)\s*=', r'let \1 =', blend)
blend += '\nreturn color;'
javascript = r'''
const assert = require('node:assert/strict');
const float2 = x => x, float3 = x => x;
const clamp = (x, low, high) => Math.min(high, Math.max(low, x));
const mix = (a, b, t) => a * (1 - t) + b * t;
const ycbcr_to_rgb = y => y; // scalar grayscale sample
const composite = new Function('u', 'eye', 'sampleG', 'overlay', 'alpha', 'handMask', 'camY', 'camCbCr', 'smp',
    'float2', 'float3', 'clamp', 'mix', 'ycbcr_to_rgb', SOURCE);
let checks = 0;
for (const eye of [0, 1]) {
 for (const mask of [0, 0.5, 1]) {
  let reads = 0;
  const camera = {sample: () => { reads++; return {r: 0.9}; }};
  const chroma = {sample: () => ({rg: 0})};
  const matte = {sample: () => ({r: mask})};
  const u = {passthrough: 0, handMaskEnabled: 1, camScaleL: 1, camScaleR: 1, camOffsetL: 0, camOffsetR: 0};
  const run = (overlay, alpha) => composite(u, eye, 0.5, overlay, alpha, matte, camera, chroma, {}, float2, float3, clamp, mix, ycbcr_to_rgb);
  assert.ok(Math.abs(run(0.3, 1) - mix(0.3, 0.9, mask)) < 1e-6); checks++;
  assert.ok(Math.abs(run(0.3, 0) - 0.9 * mask) < 1e-6); checks++;
  if (mask === 0) { assert.equal(reads, 0); checks++; }
  u.handMaskEnabled = 0;
  assert.equal(run(0.3, 1), 0.3); checks++;
  assert.equal(run(0.3, 0), 0); checks++;
  u.passthrough = 1;
  assert.equal(run(0.3, 0), 0.9); checks++;
 }
}
console.log(`PASS: ${checks} production shader hand-only blend, preserved virtual background and stereo checks`);
'''.replace('SOURCE', json.dumps(blend))

with tempfile.TemporaryDirectory(prefix='handar-foreground-') as directory:
    path = Path(directory)
    swift = path/'foreground.swift'
    swift.write_text('import Foundation\n' + uniforms + shim + '\n'.join(method(name) for name in (
        'makeUniforms', 'cameraMapping', 'syncHandMaskTexture')) +
        '\nfunc handMaskForFrame() -> Bool { ' + eligibility + '; return handMaskActive }\n' + tests, encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/CameraGeometry.swift', root/'HandARBrowser/HandGesture.swift',
                      root/'HandARBrowser/GraffitiState.swift', swift])
    script = path/'blend.cjs'
    script.write_text(javascript, encoding='utf-8')
    subprocess.run(['node', str(script)], check=True, timeout=30)

assert 'cameraPassthroughRequested || includeHands' in method('makeCameraTextures')
hands = method('handleHands')
assert hands.index('queueHandForegroundMask(left: showHands') < hands.index('handleGraffitiHands(left:')
print('PASS: graffiti mask delivery precedes input routing; camera textures support foreground-only use')
