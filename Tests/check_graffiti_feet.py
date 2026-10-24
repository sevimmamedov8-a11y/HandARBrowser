from pathlib import Path
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/GraffitiState.swift',
                   root/'HandARBrowser/GraffitiPhysics.swift', root/'Tests/GraffitiFeetTests.swift'])
studio = (root/'HandARBrowser/GraffitiStudio.swift').read_text(encoding='utf-8')
main = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
assert 'graffiti.updateFeet(head: headNode' in main
assert main.index('graffiti.updateFeet(head: headNode') < main.index('graffiti.tick(at:')
assert 'room.simdConvertPosition(head.simdWorldPosition,from:nil)' in studio
assert 'room.simdConvertVector(worldForward,from:nil)' in studio
assert 'isRunning && aligned && mode == .room && ready' in studio
assert 'continuous:active && legMotion.continuous' in studio
print('PASS: avatar uses room coordinates and tracked render frames only in virtual room')
