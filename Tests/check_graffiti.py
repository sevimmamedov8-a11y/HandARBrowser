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
    let paletteButton = Button("palette")
    var buttons = [("color-1", Button("color-1")), ("room", Button("room")), ("home", Button("home")), ("rainbow", Button("rainbow")), ("mood", Button("mood"))]
    var paintingHand: TrackedHand?, rainbow = false, mood = GraffitiRoomMood.neon, moodChanges = 0
    var roomCanvases: [Canvas] = [], homeCanvases: [Canvas] = [], undo: [(UUID, Int)] = []
    var mode = GraffitiMode.room, colors = Array(0..<8), radii = [0.01, 0.02, 0.03], colorIndex = 0, sizeIndex = 0
    var lastHandAt = -Double.infinity, lastUpload = -Double.infinity, hint = "", strokesEnded = 0
    var onInteraction: (() -> Void)?, onModeChanged: ((GraffitiMode) -> Void)?, onExit: (() -> Void)?
    func endStroke() { strokesEnded += 1; paintingHand = nil }
    func updateSelection() {}
    func updateRoomMood() { moodChanges += 1 }
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
        h.paintingHand = painted ? hand : nil
        if hand != nil { h.lastHandAt = time }
        h.tick(at: time, trackingReady: true)
        return painted
    }
    check(!frame(nil) && !frame(nil) && frame(nil), "open palm starts automatically after short confirmation")
    check(h.paintingHand == .right && !h.showsRealHand(.right) && h.showsRealHand(.left), "only drawing hand is hidden")
    check(!frame(nil, open: false) && h.showsRealHand(.right), "closing palm restores real hand immediately")
    _ = frame(nil);_ = frame(nil);check(frame(nil), "no start button needed to resume")
    for _ in 0..<60 { check(!frame("palette"), "palette hover and open panel never paint") }
    check(h.paletteOpen && confirmations == 1, "one long dwell opens palette only once")
    check(h.showsRealHand(.right) && h.showsRealHand(.left), "both hands visible in palette")
    for _ in 0..<60 { check(!frame("rainbow"), "style selection cannot leave marks") }
    check(h.rainbow && confirmations == 2, "one dwell enables rainbow")
    for _ in 0..<60 { _ = frame("mood") }
    check(h.mood == .sunset && h.moodChanges == 1, "long hover changes mood just once")
    _ = frame(nil)
    for _ in 0..<30 { _ = frame("mood") }
    check(h.mood == .mint, "leaving and returning allows next mood")
    for _ in 0..<30 { _ = frame("color-1") }
    check(h.colorIndex == 1 && !h.rainbow, "choosing a solid swatch exits rainbow mode")
    for _ in 0..<30 { _ = frame("palette") }
    check(!h.paletteOpen, "palette closes by dwell")
    check(!frame(nil) && !frame(nil) && frame(nil), "leaving palette resumes automatic palm spray after settling")
    _ = frame(nil, hand: nil)
    check(h.showsRealHand(.right) && !h.sprayGate.canVisible, "loss clears drawing state")
    check(!frame(nil) && !frame(nil) && frame(nil), "reacquisition starts a separate confirmed stroke")
    check(!frame(nil, hand: .left) && h.showsRealHand(.right), "hand change ends old stroke")
    _ = frame(nil, hand: .left);check(frame(nil, hand: .left), "left hand can start its own stroke")
    check(!h.showsRealHand(.left) && h.showsRealHand(.right), "left painting hand is hidden independently")
    h.endStroke();check(h.showsRealHand(.left), "no wall hit or completed stroke restores hand")
    h.tick(at: time + 0.3, trackingReady: true)
    check(h.paintingHand == nil && !h.sprayGate.canVisible, "watchdog clears drawing state")
    h.cancelInput()
    for _ in 0..<35 { check(!frame("palette", hand: nil, head: true), "head-only UI cannot paint") }
    check(h.paletteOpen, "head dwell still opens palette with no hands")
    _ = frame(nil, head: true)
    for _ in 0..<35 { _ = frame("palette", head: true) }
    check(!h.paletteOpen, "head dwell closes palette")
    check(!frame(nil, head: true) && !frame(nil, head: true) && frame(nil, head: true), "palm can paint with head controls")
    h.tick(at: time, trackingReady: false)
    check(h.paintingHand == nil && h.can.isHidden && h.aim.isHidden, "camera loss clears tool and drawing state")
    h.mode = .home;check(!h.showsRealHand(.left) && !h.showsRealHand(.right), "home uses its existing camera background, not cutouts")
    print("PASS: \(count) production graffiti automatic palm, hand visibility, palette, style and watchdog checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='handar-graffiti-ui-') as directory:
    script = Path(directory)/'ui.swift'
    script.write_text(shim + '\n'.join(method(name) for name in (
        'stopSpraying', 'cancelInput', 'tick', 'updateUI', 'setPalette', 'perform', 'showsRealHand')) + tests, encoding='utf-8')
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
