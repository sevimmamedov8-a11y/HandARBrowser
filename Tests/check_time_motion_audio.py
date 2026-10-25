"""Exercise the production audio bank with an AVAudioPlayer stand-in."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
source = (root / 'HandARBrowser/TimeMotionGame.swift').read_text(encoding='utf-8')
source = source[source.index('private enum TMSound:'):source.index('private func tmConstantMaterial')]
source = source.replace('private ', '')
with tempfile.TemporaryDirectory(prefix='handar-tm-audio-') as directory:
    script = Path(directory) / 'Bank.swift'
    script.write_text('import Foundation\n' + source, encoding='utf-8')
    run_swift_sources([script, root / 'Tests/TimeMotionAudioTests.swift'])
