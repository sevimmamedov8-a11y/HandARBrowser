"""Run the pure time-motion rules as native Swift tests (macOS CI, or any swiftc)."""
from pathlib import Path
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
run_swift_sources([
    root/'HandARBrowser/TimeMotionLogic.swift',
    root/'Tests/TimeMotionTests.swift',
])
print('PASS: time-motion rules compiled and executed')
