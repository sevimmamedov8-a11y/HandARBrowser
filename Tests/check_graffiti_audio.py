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
names = {'tap', 'palette', 'color', 'undo', 'reset', 'grab', 'metal', 'wood', 'soft', 'plastic', 'rubber', 'spray', 'sprayStart', 'sprayEnd', 'erase'}
assets = list((root/'HandARBrowser/GraffitiSounds').glob('*.wav'))
assert {p.stem for p in assets} == names
assert sum(p.stat().st_size for p in assets) < 650_000
for path in assets:
    with wave.open(str(path), 'rb') as wav:
        assert wav.getnchannels() == 1 and wav.getsampwidth() == 2 and wav.getframerate() == 44100
        duration = wav.getnframes()/wav.getframerate()
        assert 0.05 <= duration <= (1.7 if path.stem in ('spray','erase') else 0.5)
        samples = array.array('h', wav.readframes(wav.getnframes()))
        assert 100 < max(abs(x) for x in samples) < 27000, path.name
print('PASS: 15 original 44.1 kHz effects, no clipping, total audio under 650 KB')

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
 var enableRate = false, rate: Float = 1
 var fades: [(Float,Double)] = [], starts: [Float] = []
 func setVolume(_ value: Float, fadeDuration: Double) { fades.append((value,fadeDuration));volume = value }
 var numberOfLoops = 0, volume: Float = 1, currentTime: Double = 0, isPlaying = false, plays = 0
 init(contentsOf url: URL) throws { name = url.deletingPathExtension().lastPathComponent; Self.all.append(self) }
 func prepareToPlay() {}
 func play() { isPlaying = true; plays += 1;starts.append(volume) }
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
  check(AVAudioPlayer.all.count == 28, "prepare once: two voices per effect and two continuous loops")
  let spray = AVAudioPlayer.all.first { $0.name == "spray" }!
  check(spray.numberOfLoops == -1 && !spray.isPlaying, "spray starts silent")
  for _ in 0..<30 { audio.setSpraying(true) }
  check(spray.plays == 1 && spray.isPlaying, "continued paint does not restart hiss each frame")
  check(spray.starts.first! < 0.1 && spray.fades.last!.1 == 0.55,"continuous hiss starts quietly and ramps over 550 ms")
  let puff = AVAudioPlayer.all.filter { $0.name == "sprayStart" }
  let tail = AVAudioPlayer.all.filter { $0.name == "sprayEnd" }
  check(puff.reduce(0) { $0+$1.plays } == 1,"only one opening puff per stroke")
  audio.setSpraying(false)
  check(tail.reduce(0) { $0+$1.plays } == 1,"one pressure-release tail")
  audio.setSpraying(false)
  check(tail.reduce(0) { $0+$1.plays } == 1,"repeated end callbacks do not repeat the tail")
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
  audio.stop()
  let beforePuffs = puff.reduce(0) { $0+$1.plays }
  audio.setSpraying(true,at:100);audio.setSpraying(false,at:100.05)
  check(!spray.isPlaying && puff.reduce(0) { $0+$1.plays } == beforePuffs+1,"a 50 ms stroke remains a short puff with no lingering loop")
  audio.setSpraying(true,at:100.2);audio.setSpraying(true,at:101)
  check(spray.plays > 1 && puff.reduce(0) { $0+$1.plays } == beforePuffs+2,"next stroke restarts attack once")
  audio.setSpraying(false,at:101.1);audio.setErasing(true)
  let erase = AVAudioPlayer.all.first { $0.name == "erase" }!
  check(erase.isPlaying && !spray.isPlaying,"eraser uses a separate rubbing loop")
  audio.setBrushing(false);check(erase.isPlaying,"idle brush watchdog cannot stop an active eraser")
  audio.setErasing(false);check(!erase.isPlaying,"eraser stops on release")
  audio.setBrushing(true);let rubbingStarts = erase.plays
  audio.setErasing(false);audio.setBrushing(true)
  check(erase.isPlaying && erase.plays == rubbingStarts && erase.volume < 0.2,"brush rub is quiet and survives the spray watchdog without restarting")
  audio.setBrushing(false);check(!erase.isPlaying,"leaving brush contact stops rubbing")
  audio.play(.rubber,intensity:0.2,at:200);let ballSounds = AVAudioPlayer.all.filter { $0.name == "rubber" }
  let quiet = ballSounds.first { $0.isPlaying }!.volume
  audio.play(.rubber,intensity:0.9,at:201)
  check(ballSounds.contains { $0.volume > quiet*3 } && ballSounds.allSatisfy { (0.95...1.05).contains($0.rate) },"impact strength changes gain and modest pitch variation")
  audio.stop()
  audio.resetSettings();check(audio.enabled && audio.volumeTitle == "55%", "reset restores audible moderate volume")
  for action in ["color-0","rainbow"] { check(GraffitiSound.feedback(for:action) == .color, "color actions use distinct sound") }
  for action in ["palette","setting-close","room","home","exit"] { check(GraffitiSound.feedback(for:action) == .palette, "opening and navigation have feedback") }
  check(GraffitiSound.feedback(for:"undo") == .undo && GraffitiSound.feedback(for:"setting-props") == .reset, "undo and reset have distinct sounds")
  check(AVAudioPlayer.all.count == 28, "interactions never allocate new players")
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
assert studio.index('hit.canvas.spray(') < studio.index('audio.setSpraying(!erasing)')
stop = studio[studio.index('    func stop() {'):studio.index('    func update(anchor:')]
assert stop.index('cancelInput()') < stop.index('saveRoom(force:true)') < stop.index('audio.stop()')
assert 'sound: .metal' in studio and 'sound: .plastic' in studio and 'sound: .soft' in studio
project = (root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
assert project.count('/* GraffitiAudio.swift in Sources */') == 2
assert project.count('/* GraffitiSounds in Resources */') == 2
print('PASS: audio follows actual paint state, material feedback and packaged Xcode resources')
