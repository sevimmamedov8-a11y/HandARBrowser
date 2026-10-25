"""Execute production scene/game orchestration with lightweight platform stand-ins."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root=Path(__file__).resolve().parent.parent
source=(root/'HandARBrowser/TimeMotionGame.swift').read_text(encoding='utf-8')
# Only platform drawing/audio adapters are replaced; all gameplay and scene construction execute.
for start,end in [('private final class TMSoundBank {','private func tmConstantMaterial'),
                  ('private func tmLabelImage','private final class TMButton')]:
    a=source.index(start);b=source.index(end,a);source=source[:a]+source[b:]
source='\n'.join(line for line in source.splitlines() if not line.startswith('import ') or line == 'import Foundation')
source=source.replace('private(set) ','').replace('private ','')
with tempfile.TemporaryDirectory(prefix='handar-tm-scene-') as directory:
    script=Path(directory)/'Game.swift'
    script.write_text(source,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift',root/'HandARBrowser/GraffitiState.swift',
                      root/'HandARBrowser/VirtualHands.swift',root/'HandARBrowser/GraffitiPhysics.swift',root/'HandARBrowser/TimeMotionLogic.swift',
                      root/'Tests/TimeMotionSceneShim.swift',script,root/'Tests/TimeMotionSceneTests.swift'])
