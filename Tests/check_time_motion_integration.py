"""Static integration checks for Time Motion. Keeps the new game wired in and existing games intact."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
app = root / 'HandARBrowser'
vc = (app / 'MainViewController.swift').read_text(encoding='utf-8')
game = (app / 'TimeMotionGame.swift').read_text(encoding='utf-8')
project = (root / 'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
ci = (root / '.github/workflows/build-ipa.yml').read_text(encoding='utf-8')

# Files that must exist.
for name in ['TimeMotionLogic.swift', 'TimeMotionGame.swift', 'SecurityVRGame.swift']:
    assert (app / name).is_file(), name
sounds = ['tm_shot', 'tm_enemy_shot', 'tm_hit', 'tm_grab', 'tm_release', 'tm_shatter', 'tm_thud', 'tm_win', 'tm_lose']
for name in sounds:
    assert (app / 'TimeMotionSounds' / (name + '.wav')).is_file(), name

# Menu card, native route, frame tick, cancel and exit hooks in MainViewController.
assert vc.count("post('time-motion-game')") == 1
assert vc.count('case "time-motion-game":') == 1 and vc.count('startTimeMotionVR()') == 2
assert vc.count('tickTimeMotion(at: CACurrentMediaTime())') == 1
assert vc.count('timeMotion.cancelInput()') == 1
assert vc.count('timeMotion.stop()') == 3  # exit, leave-VR and loading scene realignment
assert 'if timeMotionActive {' in vc  # hand routing and leave-VR cleanup
start=vc[vc.index('    private func startTimeMotionVR()'):vc.index('    private func timeMotionInput(')]
assert 'tracking.start(mode: .worldTracking)' in start and 'if timeMotionCameraOverridden { tracking.start() }' in start
assert 'pauseAndMute(browser)' in start and 'queueHandForegroundMask(left: nil, right: nil)' in start
assert 'timeMotionActive ? false' in vc
assert 'guard ready else { return }' in vc[vc.index('    private func tickTimeMotion('):vc.index('    // MARK: Graffiti')]
assert vc.index('timeMotionLeft = freshLeft') < vc.index('        func eligible(_ sample: HandSample?)')
assert vc.count('post(\'security-game\')') == 1 and 'case "security-game":' in vc  # existing game kept

# Pistol and firing rules must come from the shared, tested components.
assert 'GraffitiGrabGate' in game and 'FireScheduler' in game and 'ProjectileRules.firstImpact' in game
assert 'GraffitiPropGeometry.rayDistance' in game and 'DwellProgressRing' in game

# Xcode registration: each new source appears in PBXBuildFile and the build phase; sounds folder in Resources.
assert project.count('/* TimeMotionLogic.swift in Sources */') == 2
assert project.count('/* TimeMotionGame.swift in Sources */') == 2
assert project.count('/* TimeMotionSounds in Resources */') == 2

# CI runs both new checks.
assert 'python3 Tests/check_time_motion.py' in ci and 'python3 Tests/check_time_motion_integration.py' in ci

# SecurityVRGame must stay byte-identical to the uploaded sources.
digest = hashlib.sha256((app / 'SecurityVRGame.swift').read_bytes()).hexdigest()
assert digest == '75e4179dc86523e0f97fa6da4c4c3fc0645cd847422889f655f5f4f15e492c94', 'SecurityVRGame.swift was modified'

print('PASS: Time Motion is wired into the menu, frame loop, hands, Xcode and CI; SecurityVRGame unchanged')
