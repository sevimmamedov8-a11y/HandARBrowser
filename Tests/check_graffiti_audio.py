"""Verify original PCM assets and production audio lifecycle with player doubles."""
from pathlib import Path
import array
import tempfile
import wave
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/GraffitiAudio.swift').read_text(encoding='utf-8')
enum = source[:source.index('#if canImport')]
audio = source[source.index('final class GraffitiAudio {'):source.rindex('#endif')].replace('Bundle.main', 'AudioBundle.main')
names = {'tap', 'palette', 'color', 'undo', 'reset', 'grab', 'metal', 'wood', 'soft', 'plastic', 'spray'}
assets = list((root/'HandARBrowser/GraffitiSounds').glob('*.wav'))
assert {p.stem for p in assets} == names
assert sum(p.stat().st_size for p in assets) < 150_000
for path in assets:
    with wave.open(str(path), 'rb') as wav:
        assert wav.getnchannels() == 1 and wav.getsampwidth() == 2 and wav.getframerate() == 22050
        duration = wav.getnframes()/wav.getframerate()
        assert 0.05 <= duration <= (1.3 if path.stem == 'spray' else 0.3)
        samples = array.array('h', wav.readframes(wav.getnframes()))
        assert 100 < max(abs(x) for x in samples) < 27000, path.name
print('PASS: 11 short original PCM effects, no clipping, total audio under 150 KB')

shim = r'''
import Foundation
enum AVAudioSession {
 static let interruptionNotification = Notification.Name("audioInterrupt")
 enum InterruptionType: UInt { case ended = 0, began = 1 }
}
let AVAudioSessionInterruptionTypeKey = "type"
enum UIApplication {
 static let didEnterBackgroundNotification = Notification.Name("background")
 static let didBecomeActiveNotification = Notification.Name("active")
}
struct AudioBundle {
 static let main = AudioBundle()
 func url(forResource: String, withExtension: String, subdirectory: String) -> URL? {
  precondition(subdirectory == "GraffitiSounds")
  return URL(fileURLWithPath: "/"+forResource+"."+withExtension)
 }
}
final class AVAudioPlayer {
 static var all: [AVAudioPlayer] = []
 let name: String
 var numberOfLoops = 0, volume: Float = 1, currentTime: Double = 0, isPlaying = false, plays = 0
 init(contentsOf url: URL) throws { name = url.deletingPathExtension().lastPathComponent; Self.all.append(self) }
 func prepareToPlay() {}
 func play() { isPlaying = true; plays += 1 }
 func pause() { isPlaying = false }
}
'''
tests = r'''
@main struct Tests {
 static func main() {
  var checks = 0
  func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
  let defaults = UserDefaults.standard
  let muted = defaults.object(forKey:"graffiti.sound.muted"), level = defaults.object(forKey:"graffiti.sound.level")
  defer { defaults.set(muted,forKey:"graffiti.sound.muted");defaults.set(level,forKey:"graffiti.sound.level") }
  defaults.removeObject(forKey:"graffiti.sound.muted");defaults.removeObject(forKey:"graffiti.sound.level")
  let audio = GraffitiAudio()
  audio.prepare();audio.prepare()
  check(AVAudioPlayer.all.count == 21, "prepare once: two voices per effect and one spray loop")
  let spray = AVAudioPlayer.all.first { $0.name == "spray" }!
  check(spray.numberOfLoops == -1 && !spray.isPlaying, "spray starts silent")
  for _ in 0..<30 { audio.setSpraying(true) }
  check(spray.plays == 1 && spray.isPlaying, "continued paint does not restart hiss each frame")
  audio.setSpraying(false)
  check(!spray.isPlaying && spray.currentTime == 0, "end of stroke immediately silences hiss")
  audio.play(.grab,at:1);audio.play(.grab,at:1.01);audio.play(.grab,at:1.05)
  check(AVAudioPlayer.all.filter { $0.name == "grab" }.reduce(0) { $0+$1.plays } == 2, "duplicate events filtered, two hands have separate voices")
  audio.toggle();audio.play(.metal,at:2);audio.setSpraying(true)
  check(!audio.enabled && AVAudioPlayer.all.allSatisfy { !$0.isPlaying }, "mute stops everything and blocks future events")
  audio.toggle();audio.nextVolume();audio.setSpraying(true)
  check(audio.volumeTitle == "85%" && abs(spray.volume-0.51) < 0.001, "volume setting applies to spray without restarting")
  check(GraffitiAudio().enabled && GraffitiAudio().level == 2, "sound settings persist")
  NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:nil,userInfo:[AVAudioSessionInterruptionTypeKey:UInt(1)])
  audio.setSpraying(true);audio.play(.metal,at:3)
  check(AVAudioPlayer.all.allSatisfy { !$0.isPlaying }, "interruption cannot leave or restart a loop")
  NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:nil,userInfo:[AVAudioSessionInterruptionTypeKey:UInt(0)])
  check(!spray.isPlaying, "interruption ending does not autoplay stale spray")
  audio.setSpraying(true);check(spray.isPlaying, "new active stroke can resume sound")
  NotificationCenter.default.post(name:UIApplication.didEnterBackgroundNotification,object:nil)
  audio.setSpraying(true);audio.play(.tap,at:4)
  check(AVAudioPlayer.all.allSatisfy { !$0.isPlaying }, "late callbacks cannot make background sounds")
  NotificationCenter.default.post(name:UIApplication.didBecomeActiveNotification,object:nil)
  check(!spray.isPlaying, "foreground return awaits a new stroke")
  audio.setSpraying(true);audio.stop()
  check(!spray.isPlaying && AVAudioPlayer.all.allSatisfy { !$0.isPlaying }, "exit silences every player")
  audio.resetSettings();check(audio.enabled && audio.volumeTitle == "55%", "reset restores audible moderate volume")
  for action in ["color-0","rainbow"] { check(GraffitiSound.feedback(for:action) == .color, "color actions use distinct sound") }
  for action in ["palette","setting-close","room","home","exit"] { check(GraffitiSound.feedback(for:action) == .palette, "opening and navigation have feedback") }
  check(GraffitiSound.feedback(for:"undo") == .undo && GraffitiSound.feedback(for:"setting-props") == .reset, "undo and reset have distinct sounds")
  check(AVAudioPlayer.all.count == 21, "interactions never allocate new players")
  print("PASS: \(checks) production audio preload, events, mute, volume, interruption and lifecycle checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-audio-') as directory:
    path = Path(directory)/'audio.swift'
    definitions = Path(directory)/'sounds.swift'
    definitions.write_text(enum, encoding='utf-8')
    path.write_text(shim + audio + tests, encoding='utf-8')
    run_swift_sources([definitions, path])

studio = (root/'HandARBrowser/GraffitiStudio.swift').read_text(encoding='utf-8')
assert 'paintingHand = nil; audio.setSpraying(false)' in studio
assert studio.index('hit.canvas.spray(') < studio.index('audio.setSpraying(true)')
assert 'cancelInput()\n        audio.stop()' in studio
assert 'sound: .metal' in studio and 'sound: .plastic' in studio and 'sound: .soft' in studio
project = (root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
assert project.count('/* GraffitiAudio.swift in Sources */') == 2
assert project.count('/* GraffitiSounds in Resources */') == 2
print('PASS: audio follows actual paint state, material feedback and packaged Xcode resources')
