from pathlib import Path
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/GraffitiState.swift',
                   root/'HandARBrowser/GraffitiRoomSave.swift', root/'Tests/GraffitiProgressTests.swift'])
studio = (root/'HandARBrowser/GraffitiStudio.swift').read_text(encoding='utf-8')
assert 'saveQueue.async' in studio and 'saveQueue.sync' in studio
assert 'CGImageDestinationFinalize(destination)' in studio
assert 'self.saveSession == session' in studio
assert 'force || pendingSaves == 0' in studio
assert 'saveRoom(force:true)' in studio and 'UIApplication.didEnterBackgroundNotification' in studio
assert 'saveAllowed = false' in studio
assert 'props.restore(progress.props)' in studio and 'roomCanvases[index].restore(image)' in studio
assert 'brush:true' in studio and 'brushRadius: [0.003,0.006,0.010][index]' in studio
assert 'trackingReady && !open && !blocked && !uiBlocked && !paletteOpen' in studio
assert 'textureWidth: 4096' in studio
print('PASS: autosave/restore wiring, serial PNG encoding, background save and physical brush routing')
