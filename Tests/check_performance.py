"""Run the actual Swift performance policy without requiring iOS frameworks."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parent.parent
source=(root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
start=source.index('struct VRPerformanceBudget {')
end=source.index('private final class WeakScriptMessageHandler:',start)
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
print("PASS: 33 performance policy checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-policy-') as directory:
    script=Path(directory)/'policy.swift'
    script.write_text(source[start:end]+tests,encoding='utf-8')
    subprocess.run(['swift',str(script)],check=True,timeout=30)
