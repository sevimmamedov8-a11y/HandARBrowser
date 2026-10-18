from pathlib import Path
from swift_test_support import run_swift_sources

root=Path(__file__).resolve().parent.parent
run_swift_sources([root/'HandARBrowser/HandGesture.swift',root/'HandARBrowser/HandSilhouette.swift',root/'Tests/HandGestureTests.swift'])
