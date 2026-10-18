"""Execute the actual WebInputBridge with a recording WebKit stand-in."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

r=Path(__file__).resolve().parent.parent
source=(r/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
start=source.index('final class WebInputBridge {')
end=source.index('// MARK: - Меню и калибровка',start)
stubs='''
import Foundation
typealias CFTimeInterval = Double
var clock = 1.0
func CACurrentMediaTime() -> Double { clock += 0.04; return clock }
final class WKWebView {
 var bounds = CGRect(x:0,y:0,width:1280,height:720)
 var scripts: [String] = []
 func evaluateJavaScript(_ script:String, completionHandler:((Any?,Error?)->Void)?) {scripts.append(script)}
 func count(_ name:String)->Int {scripts.filter{$0.hasPrefix("window."+name+"(")}.count}
}
'''
tests='''
let a = WKWebView(), b = WKWebView(), bridge = WebInputBridge()
let point = CGPoint(x:0.5,y:0.5)
bridge.update(normalizedPoint:point,pinch:true,webView:a,allowBegin:false)
precondition(a.count("__handarPointerDown")==0)
bridge.update(normalizedPoint:point,pinch:false,webView:a,allowBegin:false)
precondition(a.count("__handarPointerUp")==0)
bridge.update(normalizedPoint:point,pinch:true,webView:a)
bridge.update(normalizedPoint:point,pinch:true,webView:a)
precondition(a.count("__handarPointerDown")==1)
bridge.release(webView:b)
bridge.update(normalizedPoint:point,pinch:false,webView:a)
precondition(a.count("__handarPointerUp")==1)
bridge.update(normalizedPoint:point,pinch:true,webView:a)
bridge.release(webView:a)
bridge.update(normalizedPoint:point,pinch:false,webView:a)
precondition(a.count("__handarPointerUp")==1)
precondition(a.scripts.contains{$0.contains("__handarPointerCancel")})
bridge.update(normalizedPoint:point,pinch:true,webView:a)
bridge.update(normalizedPoint:point,pinch:true,webView:b,allowBegin:false)
bridge.update(normalizedPoint:point,pinch:false,webView:b,allowBegin:false)
precondition(b.count("__handarPointerDown")==0 && b.count("__handarPointerUp")==0)
bridge.update(normalizedPoint:point,pinch:true,webView:b)
bridge.update(normalizedPoint:point,pinch:false,webView:b)
precondition(b.count("__handarPointerDown")==1 && b.count("__handarPointerUp")==1)
bridge.update(normalizedPoint:point,pinch:true,webView:b)
bridge.update(normalizedPoint:CGPoint(x:Double.nan,y:0),pinch:true,webView:b)
bridge.update(normalizedPoint:point,pinch:false,webView:b)
precondition(b.count("__handarPointerUp")==1)
print("PASS: 9 native bridge lifecycle checks (including controller defaults)")
'''
with tempfile.TemporaryDirectory(prefix='handar-bridge-') as directory:
    script=Path(directory)/'bridge.swift'
    script.write_text(stubs+source[start:end]+tests,encoding='utf-8')
    run_swift_sources([script])
