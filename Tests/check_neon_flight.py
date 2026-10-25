"""Compile production flight simulation and scene with platform image/audio stand-ins."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
root=Path(__file__).resolve().parent.parent
shim=(root/'Tests/TimeMotionSceneShim.swift').read_text(encoding='utf-8')
a=shim.index('class TMSoundBank {');b=shim.index('class DwellProgressRing',a);shim=shim[:a]+shim[b:]
shim+='\nclass FlightSounds {var events:[String]=[];func prepare(){};func play(_ key:String){events.append(key)};func stop(){}}\n'
shim+='class FlightLabel:SCNNode {var text="";func set(_ value:String,width:Float){text=value}}\n'
source=(root/'HandARBrowser/NeonFlightGame.swift').read_text(encoding='utf-8')
source=source[source.index('final class NeonFlightGame {'):]
source='import Foundation\n'+source.replace('private(set) ','').replace('private ','')
logic=(root/'HandARBrowser/NeonFlightLogic.swift').read_text(encoding='utf-8').replace('private(set) ','').replace('private ','')
with tempfile.TemporaryDirectory(prefix='handar-flight-') as directory:
    files=[]
    for name,text in [('Shim.swift',shim),('Game.swift',source),('Logic.swift',logic)]:
        path=Path(directory)/name;path.write_text(text,encoding='utf-8');files.append(path)
    run_swift_sources([root/'HandARBrowser/HandGesture.swift',*files,root/'Tests/NeonFlightTests.swift'])
vc=(root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
assert vc.count("post('neon-flight')")==1 and vc.count('case "neon-flight":')==1
assert 'tickNeonFlight(at: CACurrentMediaTime())' in vc
assert 'self.inVR, !self.neonFlightActive' in vc
assert vc.count('if neonFlightActive { neonFlight.recenter(head:headNode); return }')==2
assert 'if neonFlightActive { return }' in vc[vc.index('private func handleHands('):]
assert 'neonFlight.stop();neonFlightActive=false' in vc
assert 'stamp:timeMotionHeadTimestamp' in vc
assert 'neonFlightActive ? 1.0 : 2.0' in vc
project=(root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
for name in ['NeonFlightLogic.swift','NeonFlightGame.swift']:
    assert project.count('/* '+name+' in Sources */')==2
print('PASS: native head-only flight, lifecycle, render loop and Xcode wiring')
