from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources

root = Path(__file__).resolve().parent.parent
run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/GraffitiState.swift', root/'Tests/GraffitiStateTests.swift'])
main = (root/'HandARBrowser/MainViewController.swift').read_text(encoding='utf-8')
studio = (root/'HandARBrowser/GraffitiStudio.swift').read_text(encoding='utf-8')

# Run the real spatial UI handlers with lightweight rendering stand-ins.
# This checks event ordering and the dwell latch without requiring an iOS GPU.
def method(name):
    start = studio.index('func ' + name + '(')
    end = studio.index('{', start) + 1
    depth = 1
    while depth:
        depth += (studio[end] == '{') - (studio[end] == '}')
        end += 1
    return studio[start:end]

shim = r'''
import Foundation
struct WorldRay { let target: String }
final class Node { var isHidden = false }
final class Button {
    let id: String, node = Node()
    var title = "", highlighted = false
    init(_ id: String) { self.id = id }
    func setTitle(_ title: String) { self.title = title }
    func setHighlight(_ value: Bool) { highlighted = value }
    func hitTest(ray: WorldRay) -> Bool { !node.isHidden && ray.target == id }
}
final class Ring {
    var isHidden = true
    func show(on: Node?, progress: Double) { isHidden = on == nil || progress == 0 }
}
final class Canvas {
    let id = UUID()
    var dirty = false
    func upload() { dirty = false }
    func restore(_ image: Int) { dirty = true }
}
final class Harness {
    var isRunning = true, aligned = true, paletteOpen = false, uiBlocked = false
    var uiHand: TrackedHand?, uiGate = ReleaseClickGate<String>()
    var sprayGate = GraffitiSprayGate()
    let can = Node(), aim = Node(), room = Node(), home = Node(), panel = Node(), ring = Ring()
    let paletteButton = Button("palette"), sprayButton = Button("paint")
    var buttons = [("color-1", Button("color-1")), ("room", Button("room")), ("home", Button("home"))]
    var roomCanvases: [Canvas] = [], homeCanvases: [Canvas] = [], undo: [(UUID, Int)] = []
    var mode = GraffitiMode.room, colors = Array(0..<8), radii = [0.01, 0.02, 0.03], colorIndex = 0, sizeIndex = 0
    var lastHandAt = -Double.infinity, lastUpload = -Double.infinity, hint = "", strokesEnded = 0
    var onInteraction: (() -> Void)?, onModeChanged: ((GraffitiMode) -> Void)?, onExit: (() -> Void)?
    func endStroke() { strokesEnded += 1 }
    func updateSelection() {}
    func setHint(_ text: String) { hint = text }
'''
tests = r'''
}
@main struct UITests {
 static func main() {
    var count = 0
    func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    let h = Harness()
    var time = 0.0, confirmations = 0
    h.onInteraction = { confirmations += 1 }
    @discardableResult func frame(_ target: String?, hand: TrackedHand? = .right, open: Bool = true, head: Bool = false) -> Bool {
        time += 0.04
        let blocked = h.updateUI(ray: target.map { WorldRay(target: $0) }, hand: head ? nil : hand, at: time)
        let painted = h.sprayGate.update(hand: hand, open: open, reliable: true, blocked: blocked, at: time)
        if hand != nil { h.lastHandAt = time }
        h.tick(at: time, trackingReady: true)
        return painted
    }
    for _ in 0..<60 { check(!frame("paint"), "holding enable cannot spray through UI") }
    check(h.sprayGate.isEnabled && h.sprayButton.title == "Стоп", "one dwell enables paint and changes button")
    check(confirmations == 1, "long dwell confirms exactly once")
    check(frame(nil), "paint begins only after leaving enable control")
    for _ in 0..<60 { check(!frame("paint"), "stop hover suppresses paint immediately") }
    check(!h.sprayGate.isEnabled && h.sprayButton.title == "Рисовать", "stop remains off during long hover")
    check(confirmations == 2 && !frame(nil), "no repeated toggle while held")
    for _ in 0..<30 { _ = frame("paint") }
    check(frame(nil), "new dwell can restart")
    for _ in 0..<30 { check(!frame("palette"), "palette hover pauses paint") }
    check(h.paletteOpen && !h.sprayGate.isEnabled && h.sprayButton.node.isHidden, "opening palette disables and hides enable control")
    for _ in 0..<30 { _ = frame("paint") }
    check(!h.sprayGate.isEnabled && confirmations == 4, "hidden paint button cannot be activated behind palette")
    for _ in 0..<30 { _ = frame("palette") }
    check(!h.paletteOpen && !h.sprayButton.node.isHidden && !frame(nil), "closing palette leaves spray disabled")
    for _ in 0..<30 { _ = frame("paint") }
    check(frame(nil), "explicit restart after palette")
    _ = frame(nil, hand: nil)
    check(!frame(nil) && !h.sprayGate.isEnabled, "returning palm after loss cannot resume")
    for _ in 0..<20 { _ = frame("paint") }
    for _ in 0..<10 { _ = frame("paint", hand: .left) }
    check(!h.sprayGate.isEnabled, "different hands cannot complete each other's dwell")
    for _ in 0..<25 { _ = frame("paint", hand: .left) }
    check(h.sprayGate.isEnabled && frame(nil, hand: .left), "new hand needs a full separate dwell")
    h.tick(at: time + 0.3, trackingReady: true)
    check(!h.sprayGate.isEnabled && h.sprayButton.title == "Рисовать", "render watchdog turns off stalled hand input")
    h.cancelInput()
    let previousConfirmations = confirmations
    for _ in 0..<35 { _ = frame("paint", hand: nil, head: true) }
    check(!h.sprayGate.isEnabled && confirmations == previousConfirmations, "head dwell without palm does not give false success sound")
    _ = frame(nil, head: true)
    for _ in 0..<35 { _ = frame("paint", head: true) }
    check(h.sprayGate.isEnabled && confirmations == previousConfirmations + 1, "head dwell can enable a visible palm")
    h.tick(at: time, trackingReady: false)
    check(!h.sprayGate.isEnabled && h.can.isHidden && h.aim.isHidden, "tracking loss cancels and hides paint immediately")
    print("PASS: \(count) production graffiti UI dwell, toggle, palette, head-input and watchdog checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-graffiti-ui-') as directory:
    script = Path(directory)/'ui.swift'
    script.write_text(shim + '\n'.join(method(name) for name in (
        'stopSpraying', 'cancelInput', 'tick', 'updateUI', 'setPalette', 'perform')) + tests, encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift', root/'HandARBrowser/GraffitiState.swift', script])

project = (root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
for name in ('GraffitiState', 'GraffitiStudio'):
    assert project.count(f'/* {name}.swift in Sources */') == 2
assert 'data-id="graffiti"' in main and 'case "graffiti":' in main
assert 'handleGraffitiHands(left: freshLeft, right: freshRight, at: now)' in main
assert '|| self.graffitiActive {' in main, 'head mode must still process palms while painting'
assert 'allowing: .existingPlaneGeometry, alignment: .vertical' in main
assert 'configuration.planeDetection = detectWalls ? [.vertical] : []' in main
assert 'tracking.start(mode: .worldTracking)' in main
assert 'if restoreCamera, graffitiCameraOverridden { tracking.start() }' in main
assert 'stopGraffiti(restoreCamera: false)' in main
assert 'homeCanvases.count < 12' in studio and 'undo.count > 6' in studio
assert '1.0 / 15' in studio and 'context.drawRadialGradient' in studio
assert 'anchor.geometry.boundaryVertices' in studio and 'context.closePath(); context.clip()' in studio
assert 'ARAnchor(name: "HandAR-graffiti"' in studio
assert 'onRemoveAnchor?(anchor)' in studio
assert 'time - lastHandAt > 0.2' in studio
print('PASS: graffiti AR wall detection, camera restoration, texture/undo limits and route isolation')
