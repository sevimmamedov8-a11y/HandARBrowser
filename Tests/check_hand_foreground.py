"""Exercise production camera uniforms, mask freshness and shader blend branches."""
from pathlib import Path
import json
import os
import re
import shutil
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
removal_eligibility = next(line.strip() for line in source.splitlines() if "let handRemovalActive = graffitiActive" in line)
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
 var cameraPassthroughRequested = false, panoramaActive = false, graffitiActive = false
 var graffitiTrackingReady = true
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
  h.graffitiActive = true
  check(!h.handMaskForFrame() && !h.removalForFrame(), "virtual room never samples physical hands")
  h.graffiti.mode = .home; h.cameraPassthroughRequested = true
  check(!h.handMaskForFrame(), "home does not overlay duplicate foreground")
  check(h.removalForFrame(), "home enables background replacement with a fresh mask")
  let removed = h.makeUniforms(drawableSize: size, frame: frame, hasCamera: true, handMaskActive: true, handRemovalActive: true)
  check(removed.handRemovalEnabled == 1 && removed.handMaskEnabled == 0, "home replacement cannot also draw the real hand on top")
  let noCamera = h.makeUniforms(drawableSize: size, frame: frame, hasCamera: false, handRemovalActive: true)
  check(noCamera.handRemovalEnabled == 0, "no camera cannot run replacement")
  let noProjection = h.makeUniforms(drawableSize: size, frame: CameraFrame(projection: nil), hasCamera: true, handRemovalActive: true)
  check(noProjection.handRemovalEnabled == 0, "no calibrated projection cannot run replacement")
  h.graffitiTrackingReady = false
  check(!h.removalForFrame(), "tracking loss disables replacement")
  h.graffitiTrackingReady = true
  clock = 10.2
  check(!h.removalForFrame(), "stale mask cannot remove unrelated room pixels")
  clock = 10.04
  h.graffiti.mode = .room
  let room = h.makeUniforms(drawableSize: size, frame: frame, hasCamera: true, handMaskActive: true, handRemovalActive: true)
  check(room.handRemovalEnabled == 0 && room.handMaskEnabled == 0, "virtual room rejects both physical hand effects")
  h.panoramaActive = true; h.graffitiActive = false
  let other = h.makeUniforms(drawableSize: size, frame: frame, hasCamera: true, handRemovalActive: true)
  check(other.handRemovalEnabled == 0, "replacement isolated to graffiti")
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
    'float2', 'float3', 'clamp', 'mix', 'ycbcr_to_rgb', 'concealedHandBackground', SOURCE);
let checks = 0;
for (const eye of [0, 1]) {
 for (const mask of [0, 0.5, 1]) {
  let reads = 0;
  const camera = {sample: () => { reads++; return {r: 0.9}; }};
  const chroma = {sample: () => ({rg: 0})};
  const matte = {sample: () => ({r: mask})};
  const u = {passthrough: 0, handMaskEnabled: 1, handRemovalEnabled: 0, camScaleL: 1, camScaleR: 1, camOffsetL: 0, camOffsetR: 0};
  const run = (overlay, alpha) => composite(u, eye, 0.5, overlay, alpha, matte, camera, chroma, {}, float2, float3, clamp, mix, ycbcr_to_rgb, () => 0.25);
  assert.ok(Math.abs(run(0.3, 1) - mix(0.3, 0.9, mask)) < 1e-6); checks++;
  assert.ok(Math.abs(run(0.3, 0) - 0.9 * mask) < 1e-6); checks++;
  if (mask === 0) { assert.equal(reads, 0); checks++; }
  u.handMaskEnabled = 0;
  assert.equal(run(0.3, 1), 0.3); checks++;
  assert.equal(run(0.3, 0), 0); checks++;
  u.passthrough = 1;
  assert.equal(run(0.3, 0), 0.9); checks++;
  u.handRemovalEnabled = 1;
  const filled = mix(0.9, 0.25, mask);
  assert.ok(Math.abs(run(0.3, 0) - filled) < 1e-6); checks++;
  assert.equal(run(0.3, 1), 0.3); checks++; // opaque paint/glove never erased
  assert.ok(Math.abs(run(0.3, 0.4) - mix(filled, 0.3, 0.4)) < 1e-6); checks++;
  u.passthrough = 0;
  assert.equal(run(0.3, 0), 0); checks++; // virtual room never samples physical background
 }
}
console.log(`PASS: ${checks} production shader hand-only blend, preserved virtual background and stereo checks`);
'''.replace('SOURCE', json.dumps(blend))

with tempfile.TemporaryDirectory(prefix='handar-foreground-') as directory:
    path = Path(directory)
    swift = path/'foreground.swift'
    swift.write_text('import Foundation\n' + uniforms + shim + '\n'.join(method(name) for name in (
        'makeUniforms', 'cameraMapping', 'syncHandMaskTexture')) +
        '\nfunc handMaskForFrame() -> Bool { ' + eligibility + '; return handMaskActive }\n' + '\nfunc removalForFrame() -> Bool { ' + removal_eligibility + '; return handRemovalActive }\n' + tests, encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/CameraGeometry.swift', root/'HandARBrowser/HandGesture.swift',
                      root/'HandARBrowser/GraffitiState.swift', swift])
    script = path/'blend.cjs'
    script.write_text(javascript, encoding='utf-8')
    subprocess.run(['node', str(script)], check=True, timeout=30)

    # Compile the unmodified Metal helper as C++ with scalar grayscale textures
    # and vector stand-ins. This executes the search, bounds and fallback math;
    # it does not substitute for compiling/rendering Metal on an iPhone.
    helper = source[source.index('    inline float3 concealedHandBackground('):source.index('    fragment float4 vr_fragment(')]
    cpp = r'''
extern "C" int printf(const char*, ...);
struct float2 {
 float x,y;
 float2(float a,float b):x(a),y(b){} explicit float2(float a):x(a),y(a){}
};
float2 operator+(float2 a,float2 b){return float2(a.x+b.x,a.y+b.y);}
float2 operator*(float2 a,float2 b){return float2(a.x*b.x,a.y*b.y);}
float2 operator*(float2 a,float b){return float2(a.x*b,a.y*b);}
bool operator<(float2 a,float b){return a.x<b||a.y<b;}
bool operator>(float2 a,float b){return a.x>b||a.y>b;}
bool any(bool b){return b;}
struct float3 {
 float value;
 explicit float3(float v):value(v){}
 float3& operator+=(float3 b){value+=b.value;return *this;}
};
float3 operator*(float3 a,float b){return float3(a.value*b);}
float3 operator/(float3 a,float b){return float3(a.value/b);}
float3 clamp(float3 a,float lo,float hi){return float3(a.value<lo?lo:(a.value>hi?hi:a.value));}
float3 ycbcr_to_rgb(float y,float2 cc){return float3(y);}
enum class filter {linear}; enum class address {clamp_to_edge};
struct sampler {constexpr sampler(filter f,address a){}};
float2 center(0.5,0.5);
bool covered=false;
int maskReads=0,cameraReads=0,badReads=0;
bool hand(float2 p){float dx=p.x-center.x,dy=p.y-center.y;return covered||dx*dx+dy*dy<0.0144;}
struct Pixel {float r;float2 rg;};
template<class T> struct texture2d {
 int type;
 int get_width(){return 1280;} int get_height(){return 720;}
 Pixel sample(sampler s,float2 uv){
  bool masked=hand(uv);
  if(type==0){maskReads++;return {masked?1.0f:0.0f,float2(0.0)};}
  if(type==1){cameraReads++;if(masked)badReads++;}
  return {masked?0.95f:0.25f,float2(0.5)};
 }
};
''' + helper + r'''
int main(){
 texture2d<float> mask{0},y{1},cc{2};int checks=0;
 for(int location=0;location<4;location++){
  center=float2(location%2?0.015:0.5,location/2?0.985:0.5);
  maskReads=0;cameraReads=0;badReads=0;
  float fill=concealedHandBackground(center,y,cc,mask).value;
  if(fill<0.2499||fill>0.2501)return 1;checks++;
  if(badReads!=0)return 2;checks++;
  if(maskReads>64||cameraReads>8||cameraReads==0)return 3;checks++;
 }
 covered=true;center=float2(0.5,0.5);cameraReads=0;
 float fallback=concealedHandBackground(center,y,cc,mask).value;
 if(fallback<0.1799||fallback>0.1801||cameraReads!=0)return 4;checks++;
 printf("PASS: %d production background-fill bounds, unmasked sampling and fallback checks\n",checks);
}
'''
    compiler = shutil.which('clang++')
    if compiler is None:
        raise RuntimeError('clang++ is required for compositor helper checks')
    cpp_path = path/'fill.cpp'
    cpp_path.write_text(cpp, encoding='utf-8')
    executable = path/('fill.exe' if os.name == 'nt' else 'fill')
    subprocess.run([compiler, '-std=c++17', str(cpp_path), '-o', str(executable)], check=True, timeout=60)
    subprocess.run([str(executable)], check=True, timeout=30)

assert 'cameraPassthroughRequested || includeHands' in method('makeCameraTextures')
hands = method('handleHands')
assert hands.index('handleGraffitiHands(left:') < hands.index('queueHandForegroundMask(left: removeRealHands')
assert 'right: removeRealHands ? freshRight : nil, removing: removeRealHands' in hands
assert 'graffitiActive && graffiti.mode == .home && graffitiTrackingReady' in hands
print('PASS: real-hand replacement is home-only; camera textures preserve ordinary foreground support')
