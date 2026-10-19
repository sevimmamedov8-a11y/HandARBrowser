"""Run the real navigation callbacks with recording WebKit stand-ins."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
root=Path(__file__).resolve().parent.parent
source=(root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
begin=source.index('    private func reportVideoNavigationFailure(')
end=source.index('    func webView(\n',begin)
methods=source[begin:end].replace('private func','func')
stubs=r'''
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
final class WKNavigation {}
enum WKNavigationActionPolicy { case allow, cancel }
struct Frame { var isMainFrame:Bool }
struct WKNavigationAction {var targetFrame:Frame?;var request:URLRequest}
final class Node {var isHidden=false}
final class WKWebView {
 var url:URL?;var isLoading=false;var reloads=0;var requests:[URLRequest]=[];var scripts:[String]=[]
 func load(_ request:URLRequest) {requests.append(request);url=request.url}
 func reload() {reloads+=1}
 func evaluateJavaScript(_ text:String,completionHandler:((Any?,Error?)->Void)?) {scripts.append(text)}
}
final class Harness {
 let browser=WKWebView(),directVideoLeft=WKWebView(),directVideoRight=WKWebView(),toolbarNode=Node()
 var inVR=true,cinemaActive=false,isCinemaMode=false,cinemaWebScreenActive=false
 var directVideoActive=true,liveBrowserActive=true,directVideoSyncInFlight=true
 var liveProcessRecoveries:Set<ObjectIdentifier>=[];var liveLoadErrors:[String?]=[nil,nil]
 var directVideoGeneration=UUID(),snapshotGeneration=UUID()
 var notice="",opened:[URL]=[],cancels=0,opaque=false,fallbacks=0
 func setDirectVideoNotice(_ text:String) {notice=text}
 func cancelHandInteraction() {cancels+=1}
 func activateDirectVideoAudio() {}
 func updateBrowserSnapshot() {}
 func updateVRDesktopStatus() {}
 func startCinemaWebFallback() {fallbacks+=1}
 func applySpatialSurface(home:Bool,transparent:Bool) {opaque = !transparent}
 func openExternalPage(_ url:URL) {opened.append(url)}
'''
tests=r'''
}
struct Tests {
 static func main() {
  var count=0
  func check(_ value:Bool,_ message:String) {count+=1;precondition(value,message)}
  let h=Harness(),url=URL(string:"https://www.youtube.com/watch?v=LnFf8iFs0a8")!
  func policy(_ web:WKWebView,_ value:URL,_ main:Bool=true)->WKNavigationActionPolicy {
   var result=WKNavigationActionPolicy.allow
   h.webView(web,decidePolicyFor:WKNavigationAction(targetFrame:Frame(isMainFrame:main),request:URLRequest(url:value))){result=$0}
   return result
  }
  check(policy(h.browser,url) == .cancel && h.opened==[url],"external desktop link opens a live view instead of a video snapshot")
  check(policy(h.directVideoLeft,url) == .allow && h.opened.count==1,"live page navigation is not redirected recursively")
  check(policy(h.browser,url,false) == .allow,"subframes do not replace the main page")
  check(policy(h.browser,URL(string:"https://handar.vision/notes")!) == .allow,"internal tools retain their spatial panel")
  h.cinemaActive=true
  check(policy(h.browser,url) == .allow && h.opaque,"cinema keeps its own loader and opaque screen")
  h.cinemaActive=false;h.inVR=false
  check(policy(h.browser,url) == .allow,"outside VR navigation stays in the regular browser")
  h.inVR=true
  let original=h.directVideoGeneration
  h.webViewWebContentProcessDidTerminate(h.directVideoRight)
  check(h.directVideoRight.reloads==1 && h.cancels==1,"web process loss cancels gestures and reloads once")
  check(!h.directVideoSyncInFlight && h.directVideoGeneration != original,"process loss invalidates outstanding stereo callbacks")
  h.webViewWebContentProcessDidTerminate(h.directVideoRight)
  check(h.directVideoRight.reloads==1 && h.liveLoadErrors[1] != nil,"repeated crash stops retry loop and presents recovery controls")
  h.directVideoLeft.url=url;h.directVideoRight.url=url
  h.webView(h.directVideoLeft,didFinish:nil)
  check(!h.notice.isEmpty,"successful master cannot hide a failed right eye")
  h.webView(h.directVideoRight,didStartProvisionalNavigation:nil)
  h.webView(h.directVideoRight,didFinish:nil)
  check(h.notice.isEmpty && h.liveLoadErrors[1]==nil,"successful recovery clears the error after both pages finish")
  h.reportVideoNavigationFailure(h.directVideoLeft,error:NSError(domain:NSURLErrorDomain,code:NSURLErrorCancelled))
  check(h.notice.isEmpty,"normal navigation cancellation is not an error")
  h.reportVideoNavigationFailure(h.directVideoLeft,error:NSError(domain:NSURLErrorDomain,code:NSURLErrorNotConnectedToInternet))
  check(!h.notice.isEmpty && h.liveLoadErrors[0] != nil,"offline error is visible instead of a blank page")
  h.directVideoSyncInFlight=true;let before=h.directVideoGeneration
  h.webView(h.directVideoLeft,didStartProvisionalNavigation:nil)
  check(!h.directVideoSyncInFlight && before != h.directVideoGeneration && h.liveLoadErrors[0]==nil,"new navigation discards old sync and error state")
  h.directVideoRight.url=URL(string:"https://www.youtube.com/")!
  h.webView(h.directVideoLeft,didFinish:nil)
  check(h.directVideoRight.requests.last?.url==url,"left eye redirects reconcile the right URL")
  h.cinemaWebScreenActive=true
  h.reportVideoNavigationFailure(h.directVideoRight,error:NSError(domain:NSURLErrorDomain,code:NSURLErrorTimedOut))
  check(!h.notice.contains("↻"),"cinema failure describes the available hall Home control")
  h.directVideoActive=false;h.cinemaActive=true
  h.reportVideoNavigationFailure(h.browser,error:NSError(domain:NSURLErrorDomain,code:NSURLErrorTimedOut))
  check(h.fallbacks==1,"cinema retains live-video fallback")
  print("PASS: \(count) live navigation, cancellation, process recovery and visible error checks")
 }
}
Tests.main()
'''
with tempfile.TemporaryDirectory(prefix='handar-navigation-') as directory:
    path=Path(directory)/'navigation.swift'
    path.write_text(stubs+methods+tests,encoding='utf-8')
    run_swift_sources([path])
