from pathlib import Path
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/GraffitiState.swift', root/'Tests/GraffitiStateTests.swift'])
main = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
studio = (root/'HandARBrowser/GraffitiStudio.swift').read_text(encoding='utf-8')
project = (root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
for name in ('GraffitiState', 'GraffitiStudio'):
    assert project.count(f'/* {name}.swift in Sources */') == 2
assert 'data-id="graffiti"' in main and 'case "graffiti":' in main
assert 'if graffitiActive { handleGraffitiHands' in main
assert '|| self.graffitiActive {' in main, 'head mode must still process fists while painting'
assert 'allowing: .existingPlaneGeometry, alignment: .vertical' in main
assert 'configuration.planeDetection = detectWalls ? [.vertical] : []' in main
assert 'tracking.start(mode: .worldTracking)' in main
assert 'if restoreCamera, graffitiCameraOverridden { tracking.start() }' in main
assert 'stopGraffiti(restoreCamera: false)' in main
assert 'homeCanvases.count < 12' in studio and 'undo.count > 6' in studio
assert '1.0 / 15' in studio and 'context.drawRadialGradient' in studio
assert 'anchor.geometry.boundaryVertices' in studio and 'context.closePath(); context.clip()' in studio
assert 'ARAnchor(name: "HandAR-graffiti"' in studio
assert 'onRemoveAnchor?(anchor)' in studio
assert 'time - lastHandAt > 0.2' in studio
print('PASS: graffiti AR wall detection, camera restoration, texture/undo limits and route isolation')
