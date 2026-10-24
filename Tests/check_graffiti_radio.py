"""Production music lifecycle/import checks plus packaged MP3 integrity."""
from pathlib import Path
import hashlib
import json
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/GraffitiRadio.swift').read_text(encoding='utf-8')
music = root/'HandARBrowser/GraffitiMusic'
credits = json.loads((music/'credits.json').read_text(encoding='utf-8'))
assert len(credits) == 2
for entry in credits:
    data = (music/entry['file']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == entry['sha256']
    assert 100_000 < len(data) < 5_000_000 and entry['license'] == 'CC0-1.0'
    # MP3 begins with ID3 or an MPEG audio sync header, never an HTML error.
    assert data[:3] == b'ID3' or (data[0] == 255 and data[1] & 224 == 224)
    assert entry['author'] and entry['source'].startswith('https://opengameart.org/content/')

production = source[source.index('final class GraffitiRadio:'):source.index('final class GraffitiMusicPicker:')]
production = production.replace('Bundle.main', 'MusicBundle.main')
production = production.replace('FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?', 'testLibrary')
shim = r'''
import Foundation
let testLibrary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
enum UIApplication {
 static let didEnterBackgroundNotification = Notification.Name("background")
 static let didBecomeActiveNotification = Notification.Name("active")
}
enum AVAudioSession {
 static let interruptionNotification = Notification.Name("interrupt")
 enum InterruptionType: UInt { case ended = 0, began = 1 }
}
let AVAudioSessionInterruptionTypeKey = "type"
struct MusicBundle {
 static let main = Self()
 func url(forResource: String, withExtension: String, subdirectory: String) -> URL? {
  precondition(subdirectory == "GraffitiMusic")
  return URL(fileURLWithPath:"/"+forResource+"."+withExtension)
 }
}
protocol AVAudioPlayerDelegate: AnyObject {}
final class AVAudioPlayer {
 static var all: [AVAudioPlayer] = []
 let url: URL
 weak var delegate: AVAudioPlayerDelegate?
 var volume: Float = 0, isPlaying = false, currentTime = 0.0
 init(contentsOf url: URL) throws { self.url = url; Self.all.append(self) }
 func prepareToPlay() {}
 func play() -> Bool { isPlaying = true; return true }
 func pause() { isPlaying = false }
 func stop() { isPlaying = false; currentTime = 0 }
}
#if os(Windows)
extension URL {
 func startAccessingSecurityScopedResource() -> Bool { false }
 func stopAccessingSecurityScopedResource() {}
}
#endif
'''
tests = r'''
@main struct Tests {
 static func main() throws {
  var count = 0
  func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
  let key = "graffiti.radio.volume", defaults = UserDefaults.standard
  let saved = defaults.object(forKey:key)
  defer { defaults.set(saved,forKey:key);try? FileManager.default.removeItem(at:testLibrary) }
  defaults.removeObject(forKey:key)
  let radio = GraffitiRadio()
  check(!radio.isPlaying && radio.volumeTitle == "40%", "music awaits deliberate play at moderate volume")
  radio.toggle();let first = AVAudioPlayer.all.last!
  check(radio.isPlaying && first.url.lastPathComponent.contains("Chill"), "default calm playlist starts")
  first.currentTime = 17;radio.toggle();check(!radio.isPlaying,"pause")
  radio.toggle();check(AVAudioPlayer.all.last === first && first.currentTime == 17,"resume retains position")
  radio.nextVolume();check(first.volume == 0.65 && radio.volumeTitle == "65%","independent music volume")
  radio.audioPlayerDidFinishPlaying(first,successfully:true)
  let second = AVAudioPlayer.all.last!
  check(second !== first && second.url.lastPathComponent.contains("Gone Fishin"),"playlist advances after finish")
  radio.audioPlayerDidFinishPlaying(first,successfully:true)
  check(AVAudioPlayer.all.last === second,"late finish of old player cannot skip tracks")
  NotificationCenter.default.post(name:UIApplication.didEnterBackgroundNotification,object:nil)
  radio.play();check(!radio.isPlaying,"background callbacks cannot restart music")
  NotificationCenter.default.post(name:UIApplication.didBecomeActiveNotification,object:nil)
  check(!radio.isPlaying,"foreground does not autoplay")
  radio.toggle();check(radio.isPlaying,"explicit play after background")
  NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:nil,userInfo:[AVAudioSessionInterruptionTypeKey:UInt(1)])
  radio.play();check(!radio.isPlaying,"interruption blocks sound")
  NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:nil,userInfo:[AVAudioSessionInterruptionTypeKey:UInt(0)])
  check(!radio.isPlaying,"ending interruption awaits user")
  radio.play();radio.stop();check(!radio.isPlaying,"exit stops music")
  radio.audioPlayerDidFinishPlaying(second,successfully:true)
  check(!radio.isPlaying,"late finish cannot restart after exit")
  try FileManager.default.createDirectory(at:testLibrary,withIntermediateDirectories:true)
  let song = testLibrary.appendingPathComponent("My song.m4a")
  let invalid = testLibrary.appendingPathComponent("not music.txt")
  try Data([1,2,3]).write(to:song);try Data([1]).write(to:invalid)
  radio.importSongs([invalid,song])
  let library = testLibrary.appendingPathComponent("GraffitiMusic")
  check(try FileManager.default.contentsOfDirectory(atPath:library.path).count == 1,"import accepts supported music only")
  check(radio.isPlaying && radio.title.contains("My song"),"imported playlist starts")
  try FileManager.default.removeItem(at:song)
  radio.stop();radio.ownMusic();check(radio.isPlaying,"imported copy outlives original document")
  radio.builtIn();check(!radio.isPlaying && radio.title.contains("Chill"),"built-in playlist restored")
  radio.play();radio.next();radio.next()
  check(radio.title.contains("Chill"),"calm playlist wraps")
  let copy = try FileManager.default.contentsOfDirectory(at:library,includingPropertiesForKeys:nil)[0]
  radio.importSongs(Array(repeating:copy,count:30))
  check(try FileManager.default.contentsOfDirectory(atPath:library.path).count == 24,"bounded imported library")
  check(GraffitiRadio().volumeTitle == "65%","volume persists")
  print("PASS: \(count) production music playback, playlist, import and lifecycle checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-radio-') as directory:
    script = Path(directory)/'radio.swift'
    script.write_text(shim+production, encoding='utf-8')
    harness = Path(directory)/'tests.swift'
    harness.write_text('import Foundation\n'+tests, encoding='utf-8')
    run_swift_sources([script,harness])
project = (root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
assert project.count('/* GraffitiMusic in Resources */') == 2
assert project.count('/* GraffitiRadio.swift in Sources */') == 2
assert 'forOpeningContentTypes: [.audio], asCopy: true' in source
assert 'stopAccessingSecurityScopedResource()' in source
print('PASS: two attributed local MP3s, SHA-256 integrity, native picker and Xcode packaging')
