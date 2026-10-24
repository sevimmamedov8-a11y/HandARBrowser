import Foundation

@main struct ProgressTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value,label); checks += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handar-progress-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("room.plist"), store = GraffitiRoomStore(url:directory.appendingPathComponent("room.plist"))
        check(try store.load() == nil,"first launch has no saved room")
        var archive = GraffitiRoomArchive()
        archive.progress.color = 5; archive.progress.mood = 2
        archive.progress.props = [GraffitiPropSave(id:"brush#10",position:SIMD3(1,-0.5,2),angles:SIMD3(0.1,0.2,0.3),free:true,moving:false)]
        // The portable store preserves image bytes; real PNG pixels are checked on macOS.
        let png = Data([137,80,78,71,13,10,26,10,1,2,3])
        archive.walls[2] = png
        try store.write(archive)
        let reloaded = try GraffitiRoomStore(url:url).load()!
        check(reloaded.progress == archive.progress && reloaded.walls == archive.walls,"new instance restores metadata and wall bytes")
        check(reloaded.walls[0].isEmpty && reloaded.walls[2] == png,"wall order and untouched walls preserved")
        var second = archive; second.progress.color = 3; second.progress.props[0].position.x = 2
        try store.write(second)
        check(try store.load()!.progress == second.progress,"latest complete save replaces old state")
        try Data("interrupted file".utf8).write(to:url)
        check(try store.load()!.progress == archive.progress,"corrupt current file recovers previous valid snapshot")
        try store.write(second)
        for fault in 0..<6 {
            var broken = second
            switch fault {
            case 0: broken.version = 999
            case 1: broken.progress.props[0].position.x = .nan
            case 2: broken.progress.color = 99
            case 3: broken.walls = [Data()]
            case 4: broken.walls[0] = Data("not PNG".utf8)
            default: broken.progress.props.append(broken.progress.props[0])
            }
            do { try store.write(broken); preconditionFailure("invalid snapshot accepted") }
            catch { check(try store.load()!.progress == second.progress,"invalid snapshot cannot replace good save") }
        }
        let queue = DispatchQueue(label:"progress-test")
        for color in 0..<8 {
            var version = second; version.progress.color = color
            let snapshot = version
            queue.async { try! store.write(snapshot) }
        }
        let last = try queue.sync { try store.load()! }
        check(last.progress.color == 7,"rapid exit/reentry waits for the newest queued save")
        check(try Data(contentsOf:url).starts(with:Data("bplist".utf8)),"archive is a binary plist")
        let bad = directory.appendingPathComponent("bad.plist")
        try Data([1,2,3]).write(to:bad)
        do { _ = try GraffitiRoomStore(url:bad).load(); preconditionFailure("corruption silently erased") }
        catch { check(try Data(contentsOf:bad) == Data([1,2,3]),"unrecoverable file stays intact") }

        var contact = GraffitiBrushContact()
        func frame(_ time: Double, x: Double = 0, wall: Int? = 0, depth: Double = 0.01, allowed: Bool = true) -> (began: Bool, points: [SIMD2<Double>]) {
            contact.update(wall:wall,point:SIMD2(x,0),depth:depth,radius:0.003,allowed:allowed,at:time)
        }
        check(frame(0,depth:0.03).points.isEmpty && contact.wall == nil,"hovering away from wall cannot start brush")
        check(frame(0.04).points.isEmpty,"one fleeting contact does not draw")
        check(frame(0.08).began,"stable tip contact begins one undoable stroke")
        check(frame(0.12).points.isEmpty,"stationary opaque brush does not allocate repeated image changes")
        let moving = frame(0.16,x:0.02,depth:0.035)
        check(!moving.began && moving.points.count > 1,"small movement interpolates a fine continuous line with contact hysteresis")
        check(frame(0.20,x:0.03,depth:0.06).points.isEmpty && contact.wall == nil,"leaving wall ends stroke")
        _ = frame(0.24,x:0.03);check(frame(0.28,x:0.035).began,"next contact is a separate undoable stroke")
        check(frame(0.32,allowed:false).points.isEmpty && contact.wall == nil,"palette or opening hand cannot paint")
        _ = frame(0.36);_ = frame(0.40)
        check(frame(1.0,depth:0.035).points.isEmpty && contact.wall == nil,"reacquisition requires close contact again")
        _ = frame(1.04);_ = frame(1.08,x:0.01)
        check(frame(1.12,x:0.5).points.isEmpty,"tracking jump does not draw a long slash")
        check(frame(1.16,x:0.5,wall:1).points.isEmpty,"changing walls starts new confirmation")
        check(frame(1.20,x:0.51,wall:1).began,"new wall gets its own stroke")
        check(frame(1.24,depth:-0.02).points.isEmpty && contact.wall == nil,"tip behind wall cannot draw")
        check(frame(.nan).points.isEmpty,"invalid time is rejected")
        var left = GraffitiBrushContact(), right = GraffitiBrushContact()
        for time in [0.0,0.04] { _ = left.update(wall:0,point:.zero,depth:0.01,radius:0.003,allowed:true,at:time) }
        check(right.wall == nil && left.wall == 0,"each hand owns independent contact history")
        right.cancel();check(left.wall == 0,"losing one brush cannot cancel the other")
        print("PASS: \(checks) room persistence, recovery, validation, save ordering and fine brush contact checks")
    }
}
