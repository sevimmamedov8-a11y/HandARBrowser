"""Run real Security VR shift rules and decisions without SceneKit."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/SecurityVRGame.swift').read_text(encoding='utf-8')
rules = source[source.index('struct SecurityShiftProgress {'):source.index('final class SecurityVRGame {')]

def method(name):
    start = source.index('    private func '+name)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func ', 'func ')

shim = r'''
import Foundation
enum Phase { case atGate, attacking, leaving }
final class Label { var text = ""; func setText(_ value: String) { text = value } }
final class Guest {
 var phase = Phase.atGate
 var hasContraband = false, isDrunk = false, isAggressive = false
 var scanned = false, breathTested = false
 func beginAttack() { phase = .attacking }
 func leave(accepted: Bool) { phase = .leaving }
}
final class Harness {
 var guest: Guest? = Guest()
 var wave = 1, servedInWave = 0, score = 0, money = 0, hudUpdates = 0
 var walkSpeed: Float = 0.8, contrabandChance: Float = 0.35
 var drunkChance: Float = 0.30, aggressiveChance: Float = 0.25
 var progress = SecurityShiftProgress()
 let toastLabel = Label(), hintLabel = Label()
 func refreshHUD() { hudUpdates += 1 }
'''
tests = r'''
}
var checks = 0
func check(_ value: Bool) { precondition(value); checks += 1 }
for wave in 1...6 {
 for contraband in [false,true] { for drunk in [false,true] { for aggressive in [false,true] {
  for accept in [false,true] {
   let game = Harness(), guest = game.guest!
   game.wave = wave; guest.scanned = true; guest.breathTested = true
   guest.hasContraband = contraband; guest.isDrunk = drunk; guest.isAggressive = aggressive
   let allowed = !contraband && !drunk && (wave % 3 != 0 || !aggressive)
   check(SecurityShiftProgress.admits(contraband:contraband,drunk:drunk,aggressive:aggressive,wave:wave) == allowed)
   game.decide(accept: accept)
   check(game.progress.decisions == 1 && game.progress.correct == (accept == allowed ? 1 : 0))
   check(game.servedInWave == 1 && guest.phase != .atGate)
   let score = game.score
   game.decide(accept:accept)
   check(game.progress.decisions == 1 && game.score == score) // held/repeated decisions ignored
  }
 }}}
}
for scanned in [false,true] { for breath in [false,true] {
 let game = Harness(); game.wave = 2
 game.guest!.scanned = scanned; game.guest!.breathTested = breath
 game.decide(accept:true)
 check(game.progress.decisions == (scanned && breath ? 1 : 0))
 check(game.servedInWave == (scanned && breath ? 1 : 0))
}}
var progress = SecurityShiftProgress()
for index in 1...10 { check(progress.record(correct:true) == min((index-1)*10,50)) }
check(progress.accuracy == 100 && progress.longestStreak == 10)
check(progress.record(correct:false) == 0 && progress.streak == 0)
check(progress.accuracy == 90 && progress.longestStreak == 10)
let game = Harness(); game.servedInWave = 4; game.decide(accept:true)
check(game.wave == 2 && game.servedInWave == 0)
check(SecurityShiftProgress.requiresInspection(wave:game.wave))
for _ in 0..<60 { game.nextWave() }
check(game.walkSpeed <= 2 && game.contrabandChance <= 0.7 && game.drunkChance <= 0.6 && game.aggressiveChance <= 0.55)
print("PASS: \(checks) Security VR decisions, inspection gates, streak, accuracy, repeated input and shift progression checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-security-') as directory:
    script = Path(directory)/'security.swift'
    script.write_text('import Foundation\n'+rules+shim+method('decide')+'\n'+method('nextWave')+tests, encoding='utf-8')
    run_swift_sources([script])

# Lifecycle ordering protects against loss-of-hand rewards and off-target scans.
update = source[source.index('    func update(ray: WorldRay?'):source.index('    // MARK: Логика')]
assert update.index('if ray == nil') < update.index('updateGuest(dt: dt)')
assert update.index('if paused || rulesVisible') < update.index('updateGuest(dt: dt)')
assert 'releaseHold(cancelled: true)' in source
assert 'if !dwell, heldItem == nil' in update
assert '(pinch || dwell)' in update and 'guest.cancelScan()' in update
assert 'toolDwellGate.update' in update
assert 'securityVR.bestScore' in source
print('PASS: Security VR pause/loss/scan/dwell integration guards')
