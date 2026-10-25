"""Run the actual Swift performance policy without requiring iOS frameworks."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
root=Path(__file__).resolve().parent.parent
source=(root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
start=source.index('struct VRPerformanceBudget {')
end=source.index('// Unit-square to quadrilateral mapping.',start)
tests='''
for level in 0...4 {
 let b = VRPerformanceBudget(thermalLevel: level)
 precondition(b.snapshotInterval(home: true, cinema: false, interacting: false) == 1.0 / 6.0)
 precondition(b.snapshotInterval(home: true, cinema: false, interacting: true) == 1.0 / 12.0)
 precondition(b.snapshotInterval(home: false, cinema: false, interacting: false) == 1.0 / 12.0)
 precondition(b.snapshotInterval(home: false, cinema: true, interacting: false) == (level >= 2 ? 1.0 / 12.0 : 1.0 / 24.0))
 precondition(b.handFrameInterval >= 1.0 / 30.0)
 precondition(b.maximumRenderScale > 0 && b.maximumRenderScale <= 2)
}
precondition(VRPerformanceBudget(thermalLevel: 2).handFrameInterval == 1.0 / 20.0)
precondition(VRPerformanceBudget(thermalLevel: 3).handFrameInterval == 1.0 / 15.0)
precondition(VRPerformanceBudget(thermalLevel: 3).maximumRenderScale == 0.85)
var snapshots=VRMenuSnapshotGate()
precondition(snapshots.shouldCapture(at:0,home:true,loading:false))
precondition(!snapshots.shouldCapture(at:0.2,home:true,loading:false))
precondition(snapshots.shouldCapture(at:2.1,home:true,loading:false))
snapshots.markChanged(at:2.2)
precondition(snapshots.shouldCapture(at:2.21,home:true,loading:false))
precondition(snapshots.shouldCapture(at:2.38,home:true,loading:false))
precondition(!snapshots.shouldCapture(at:2.6,home:true,loading:false))
precondition(snapshots.shouldCapture(at:2.7,home:false,loading:false))
precondition(snapshots.shouldCapture(at:2.8,home:true,loading:true))
snapshots.reset();precondition(snapshots.shouldCapture(at:3,home:true,loading:false))
var governor=VRMenuFrameGovernor()
for i in 0..<180 {governor.sample(at:Double(i)/35,home:true)}
precondition(governor.scale>=0.7 && governor.scale<0.9)
let reduced=governor.scale
for i in 180..<780 {governor.sample(at:180.0/35+Double(i-180)/60,home:true)}
precondition(governor.scale>reduced && governor.scale<=1)
let previous=governor.scale
governor.sample(at:.infinity,home:true)
precondition(governor.scale==previous)
print("PASS: performance policy, static-menu capture and adaptive-resolution checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-policy-') as directory:
    script=Path(directory)/'policy.swift'
    script.write_text(source[start:end]+tests,encoding='utf-8')
    run_swift_sources([script])

assert 'vrView.preferredFramesPerSecond = 60' in source
assert 'menuSnapshotGate.shouldCapture(' in source
assert 'menuFrameGovernor.sample(' in source
assert 'image == nil {self.menuSnapshotGate.markChanged' in source
print('PASS: 60 FPS render target, desktop cache, resolution feedback and failed-snapshot recovery wiring')
