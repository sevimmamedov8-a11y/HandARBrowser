"""Execute production WebKit status polling and manual recovery with recording shims."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')

def method(name):
    start = source.index('    private func ' + name + '(')
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

shim = r'''
import Foundation
var clock = 0.0
func CACurrentMediaTime()->Double { clock }
final class AVAudioSession {
 static func sharedInstance()->AVAudioSession { AVAudioSession() }
 var outputVolume:Float=1
}
final class Web {
 var url:URL? = URL(string:"https://m.youtube.com/watch?v=LnFf8iFs0a8")
 var callback:((Any?,Error?)->Void)?
 func evaluateJavaScript(_ script:String,completionHandler:((Any?,Error?)->Void)?) {callback=completionHandler}
}
final class Hall {
 var reload=false,playing=false,current=0.0
 func setReloadAvailable(_ available:Bool){reload=available}
 func setSoundEnabled(_ enabled:Bool){}
 func setPlayingState(_ value:Bool){playing=value}
 func setTime(current:Double,duration:Double){self.current=current}
}
final class Ownership {var suppressed=false;func suppressUntilOpen(){suppressed=true}}
final class Harness {
 var directVideoActive=true,cinemaWebScreenActive=true,directVideoSyncInFlight=false
 var directVideoGeneration=UUID(),liveLoadError:String?
 var cinemaWebLoadStartedAt=0.0,cinemaWebRecoveryRequired=false,notice="",cancels=0
 var directVideoURL:URL?,cinemaOriginalURL:URL?,loaded:[URL]=[]
 let directVideoLeft=Web(),cinemaHall=Hall(),handOwnership=Ownership()
 func setDirectVideoNotice(_ value:String){notice=value}
 func cancelHandInteraction(){cancels+=1}
 func presentDirectVideoStage(url:URL){loaded.append(url)}
 func poll(_ response:String?){syncDirectVideoEyes();directVideoLeft.callback?(response,nil)}
'''
tests = r'''
}
let h=Harness()
var count=0
func check(_ value:Bool,_ reason:String){precondition(value,reason);count+=1}
clock=19;h.poll("null")
check(!h.cinemaWebRecoveryRequired,"normal startup has a grace period")
clock=20;h.poll("{\"missing\":true}")
check(h.cinemaWebRecoveryRequired && h.cinemaHall.reload,"missing player enables manual retry")
check(h.notice.contains("Обновить"),"slow page explains recovery")
check(!h.directVideoSyncInFlight,"missing player releases poll latch")
for _ in 0..<20 {clock+=1;h.poll("null")}
check(h.loaded.isEmpty,"slow page never enters an automatic reload loop")
h.poll("{\"missing\":true,\"e\":\"YouTube error 123\"}")
check(h.notice.contains("YouTube error 123") && h.cinemaHall.reload,"page error survives without media metadata")
h.poll("{\"t\":0,\"p\":true,\"r\":0}")
check(h.cinemaHall.reload,"empty media buffer retains recovery option")
h.retryCinemaWebVideo()
check(h.loaded==[h.directVideoLeft.url!],"retry loads current video, not the original homepage")
check(h.cancels==1 && h.handOwnership.suppressed,"reload cancels held input")
h.poll("{\"t\":12,\"p\":false,\"r\":4,\"m\":false,\"v\":1}")
check(!h.cinemaWebRecoveryRequired && !h.cinemaHall.reload,"recovered video restores Restart action")
check(h.notice.isEmpty && h.cinemaHall.playing && h.cinemaHall.current==12,"success clears error and updates progress")
clock+=2
h.poll("{\"t\":12,\"p\":true,\"r\":1}")
check(!h.cinemaWebRecoveryRequired,"brief buffering after playback does not immediately suggest reload")
clock+=21
h.poll("{\"t\":12,\"p\":true,\"r\":1}")
check(h.cinemaWebRecoveryRequired,"continuous buffering has its own timeout")
h.poll("{\"t\":0,\"p\":true,\"r\":1,\"b\":true}")
check(!h.cinemaWebRecoveryRequired && h.notice.contains("Смотреть"),"autoplay block asks for Play instead of Reload")
h.liveLoadError="Network offline"
h.poll("null")
check(h.notice=="Network offline" && h.cinemaHall.reload,"network error is retained")
h.liveLoadError=nil
h.syncDirectVideoEyes();let old=h.directVideoLeft.callback
h.directVideoGeneration=UUID();h.directVideoSyncInFlight=false;h.notice="New page"
old?("{\"missing\":true,\"e\":\"Old error\"}",nil)
check(h.notice=="New page","late callback cannot replace new page status")
h.cinemaWebScreenActive=false;let n=h.loaded.count
h.retryCinemaWebVideo()
check(h.loaded.count==n,"retry does nothing outside cinema")
h.setCinemaWebRecovery(true)
check(!h.cinemaWebRecoveryRequired,"ordinary browser cannot change cinema Restart action")
print("PASS: \(count) cinema load timeout, visible errors, manual retry and stale callback checks")
'''
with tempfile.TemporaryDirectory(prefix='handar-cinema-recovery-') as directory:
    script = Path(directory)/'main.swift'
    methods = '\n'.join(method(n) for n in ['syncDirectVideoEyes','setCinemaWebRecovery','updateCinemaWebWaiting','retryCinemaWebVideo'])
    script.write_text(shim+methods+tests, encoding='utf-8')
    run_swift_sources([script])

assert 'if isYouTubePage(requested)' in source
assert 'if cinemaWebScreenActive, cinemaWebRecoveryRequired { retryCinemaWebVideo(); return }' in source
