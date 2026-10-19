"""Exercise production audio activation and volume methods with platform shims."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
controller = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
playback = (root/'HandARBrowser/CinemaPlayback.swift').read_text(encoding='utf-8')

def method(source, name):
    start = source.index('    private func '+name) if '    private func '+name in source else source.index('    func '+name)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func ', 'func ')

shim = r'''
import Foundation
enum AudioError: Error { case invalidOptions, interrupted }
final class AVAudioSession {
 enum Category { case playback }
 enum Mode { case moviePlayback }
 struct Options: OptionSet {
  let rawValue: Int
  static let allowBluetoothA2DP = Options(rawValue: 1)
  static let notifyOthersOnDeactivation = Options(rawValue: 2)
 }
 static let instance = AVAudioSession()
 static func sharedInstance() -> AVAudioSession { instance }
 var active = false, failActivation = false, activations = 0, deactivations = 0
 func setCategory(_ category: Category, mode: Mode, options: Options) throws {
  if options.contains(.allowBluetoothA2DP) { throw AudioError.invalidOptions }
 }
 func setActive(_ value: Bool, options: Options = []) throws {
  if value { activations += 1; if failActivation { throw AudioError.interrupted } }
  else { deactivations += 1; precondition(options.contains(.notifyOthersOnDeactivation)) }
  active = value
 }
}
final class Player { var volume: Float = 1; var isMuted = true }
final class Harness {
 var mediaAudioSessionActive = false
 var player: Player? = Player()
'''
methods = '\n'.join(method(controller, n) for n in ['activateMediaAudioSession', 'deactivateMediaAudioSession', 'activateDirectVideoAudio'])
methods += '\n'+method(playback, 'setVolume')
methods += '\n'+next(line for line in playback.splitlines() if 'var isSoundEnabled:' in line)
tests = r'''
}
let harness = Harness(), session = AVAudioSession.sharedInstance()
var checks = 0
func check(_ value: Bool) { precondition(value); checks += 1 }
harness.activateMediaAudioSession()
check(session.active && harness.mediaAudioSessionActive)
harness.activateDirectVideoAudio()
check(session.activations == 2) // retry even with a previously active flag
session.failActivation = true
harness.activateDirectVideoAudio()
check(!harness.mediaAudioSessionActive)
session.failActivation = false
harness.activateDirectVideoAudio()
check(harness.mediaAudioSessionActive && session.activations == 4)
harness.deactivateMediaAudioSession()
check(!session.active && !harness.mediaAudioSessionActive && session.deactivations == 1)
harness.deactivateMediaAudioSession()
check(session.deactivations == 1)
check(!harness.isSoundEnabled)
harness.setVolume(0.65)
check(harness.isSoundEnabled && harness.player!.volume == 0.65)
harness.setVolume(-1)
check(!harness.isSoundEnabled && harness.player!.volume == 0)
harness.setVolume(2)
check(harness.isSoundEnabled && harness.player!.volume == 1)
harness.setVolume(.nan)
harness.setVolume(.infinity)
check(harness.player!.volume == 1)
harness.player = nil
harness.setVolume(0.5)
check(!harness.isSoundEnabled)
print("PASS: \(checks) native cinema audio checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-audio-') as directory:
    script = Path(directory)/'audio.swift'
    script.write_text(shim+methods+tests, encoding='utf-8')
    run_swift_sources([script])
