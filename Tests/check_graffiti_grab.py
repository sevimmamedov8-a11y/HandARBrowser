from pathlib import Path
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/GraffitiState.swift', root/'Tests/GraffitiGrabTests.swift'])
source = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
handler = source[source.index('    private func handleGraffitiHands('):source.index('    private func graffitiHandDistance(')]
assert handler.index('graffiti.updateProp(') < handler.index('graffiti.updateHand(')
assert 'VirtualHandPose.fresh($0.timestamp, at: time)' in handler
assert 'for hand in [TrackedHand.left, .right]' in handler and 'generation: tracked?.generation' in handler
project = (root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
assert project.count('/* GraffitiProps.swift in Sources */') == 2
print('PASS: both hands feed fresh samples to object interaction before paint; Xcode source registered')
