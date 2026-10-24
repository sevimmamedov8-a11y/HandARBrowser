import Foundation

struct GraffitiPropSave: Codable, Equatable {
    var id: String
    var position: SIMD3<Float>
    var angles: SIMD3<Float>
    var free: Bool
    var moving: Bool
    var valid: Bool {
        !id.isEmpty && id.count < 120 && (0..<3).allSatisfy {
            position[$0].isFinite && abs(position[$0]) <= 20 && angles[$0].isFinite && abs(angles[$0]) < 10000
        }
    }
}

struct GraffitiRoomProgress: Codable, Equatable {
    var props: [GraffitiPropSave] = []
    var color = 0, size = 1, mood = 0
    var rainbow = false, erasing = false
    var valid: Bool {
        props.count <= 64 && props.allSatisfy(\.valid) && Set(props.map(\.id)).count == props.count &&
        (0..<8).contains(color) && (0..<3).contains(size) && (0..<3).contains(mood)
    }
}

struct GraffitiRoomArchive: Codable {
    var version = 1
    var progress = GraffitiRoomProgress()
    // Empty data means an untouched wall, not a transparent bitmap.
    var walls = [Data](repeating: Data(), count: 4)
    var valid: Bool {
        version == 1 && progress.valid && walls.count == 4 && walls.allSatisfy {
            $0.isEmpty || ($0.count <= 32_000_000 && $0.starts(with: [137,80,78,71,13,10,26,10]))
        }
    }
}

/// One atomic file keeps the wall images and object transforms from different
/// saves from becoming mixed. Call on the studio's serial utility queue.
final class GraffitiRoomStore {
    enum Failure: Error { case unavailable, invalid }
    private let url: URL?
    init(url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("HandARGraffiti/room-v1.plist")) { self.url = url }
    private func read(_ url: URL) throws -> GraffitiRoomArchive {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 128_000_000 else { throw Failure.invalid }
        let value = try PropertyListDecoder().decode(GraffitiRoomArchive.self, from: Data(contentsOf: url))
        guard value.valid else { throw Failure.invalid }
        return value
    }
    func load() throws -> GraffitiRoomArchive? {
        guard let url else { throw Failure.unavailable }
        let backup = url.appendingPathExtension("backup")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FileManager.default.fileExists(atPath: backup.path) ? try read(backup) : nil
        }
        do { return try read(url) }
        catch { if let restored = try? read(backup) { return restored }; throw error }
    }
    func write(_ value: GraffitiRoomArchive) throws {
        guard let url else { throw Failure.unavailable }
        guard value.valid else { throw Failure.invalid }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        guard data.count <= 128_000_000 else { throw Failure.invalid }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = try? read(url) {
            try encoder.encode(previous).write(to: url.appendingPathExtension("backup"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
}

/// Independent contact state per hand. Brush contact cannot bridge a tracking
/// gap, change of wall, UI interaction or an opening used to release the brush.
struct GraffitiBrushContact {
    private(set) var wall: Int?
    private var last: Double?
    private var since: Double?
    private var filtered: SIMD2<Double>?
    private var sampler = GraffitiStrokeSampler()
    private var painting = false
    private var lastDrawPoint: SIMD2<Double>?
    mutating func cancel() { self = Self() }
    mutating func update(wall next: Int?, point: SIMD2<Double>, depth: Double, radius: Double,
                         allowed: Bool, at time: Double) -> (began: Bool, points: [SIMD2<Double>]) {
        if wall != next || last.map({ time < $0 || time-$0 > 0.2 }) == true { cancel() }
        if let previous = filtered, hypot(point.x-previous.x,point.y-previous.y) > 0.12 { cancel() }
        guard allowed, let next, time.isFinite, depth.isFinite, point.x.isFinite, point.y.isFinite,
              radius.isFinite, radius > 0,
              depth >= -0.015, depth <= (wall == next ? 0.045 : 0.025) else {
            cancel(); return (false, [])
        }
        let dt = last.map { max(0,time-$0) } ?? 0
        last = time; wall = next
        if since == nil { since = time }
        let alpha = min(1,max(0.25,dt/0.055))
        filtered = filtered.map { $0+(point-$0)*alpha } ?? point
        guard time-(since ?? time) >= 0.035 else { return (false,[]) }
        if let previous = lastDrawPoint, let point = filtered,
           hypot(point.x-previous.x,point.y-previous.y) < radius*0.12 { return (false,[]) }
        let points = sampler.points(to: filtered!, radius: radius, at: time)
        let began = !painting && !points.isEmpty
        if !points.isEmpty { painting = true; lastDrawPoint = filtered }
        return (began,points)
    }
}
