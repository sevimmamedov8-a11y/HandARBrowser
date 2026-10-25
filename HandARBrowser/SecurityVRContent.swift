import Foundation

enum SecurityGoods: Int, CaseIterable {
    case chain, camera, skateboard, headphones, speaker, sealedCase, bottle
    var title: String { ["Цепочка","Камера","Скейт","Наушники","Колонка","Закрытый кейс","Бутылка"][rawValue] }
    var buyPrice: Int { [35,75,45,40,55,0,12][rawValue] }
    var sellPrice: Int { [22,48,28,25,34,18,7][rawValue] }
    func forbidden(wave: Int) -> Bool {
        self == .sealedCase || self == .bottle || (wave % 3 == 1 && self == .chain)
            || (wave % 3 == 0 && (self == .skateboard || self == .speaker))
    }
    static func rule(wave: Int) -> String {
        wave % 3 == 1 ? "Без цепочек" : (wave % 3 == 0 ? "Без скейтов и колонок" : "Украшения разрешены")
    }
}

struct SecurityInventory {
    enum Holder: Equatable { case guest(UUID), player, sold }
    struct Entry { let kind: SecurityGoods; var holder: Holder }
    private(set) var entries: [UUID:Entry] = [:]
    static let capacity = 8
    var count: Int { entries.values.filter { $0.holder == .player }.count }
    mutating func register(_ id: UUID, kind: SecurityGoods, guest: UUID) {
        guard entries[id] == nil else { return }
        entries[id] = Entry(kind:kind,holder:.guest(guest))
    }
    mutating func acquire(_ id: UUID, from guest: UUID, wave: Int, confiscate: Bool, money: inout Int) -> Bool {
        guard var entry = entries[id], entry.holder == .guest(guest), count < Self.capacity else { return false }
        if confiscate { guard entry.kind.forbidden(wave:wave) else { return false } }
        else {
            guard entry.kind != .sealedCase, money >= entry.kind.buyPrice else { return false }
            money -= entry.kind.buyPrice
        }
        entry.holder = .player; entries[id] = entry
        return true
    }
    mutating func sell(_ id: UUID, money: inout Int) -> Bool {
        guard var entry = entries[id], entry.holder == .player else { return false }
        money += entry.kind.sellPrice; entry.holder = .sold; entries[id] = entry
        return true
    }
    mutating func discardGuest(_ guest: UUID) {
        entries = entries.filter { $0.value.holder != .guest(guest) && $0.value.holder != .sold }
    }
}

/// Fixed-step articulated body, simulated locally so pausing/tracking loss freezes every joint.
struct SecurityRagdoll {
    struct Link { let a: Int, b: Int; let length: Float }
    struct Obstacle { let low: SIMD3<Float>, high: SIMD3<Float> }
    static let rest: [SIMD3<Float>] = [SIMD3(0,0.85,0),SIMD3(0,1.22,0),SIMD3(0,1.58,0),
        SIMD3(-0.23,1.27,0),SIMD3(-0.30,0.99,0.02),SIMD3(-0.32,0.72,0.06),
        SIMD3(0.23,1.27,0),SIMD3(0.30,0.99,0.02),SIMD3(0.32,0.72,0.06),
        SIMD3(-0.11,0.84,0),SIMD3(-0.11,0.46,0),SIMD3(-0.11,0.09,0.07),
        SIMD3(0.11,0.84,0),SIMD3(0.11,0.46,0),SIMD3(0.11,0.09,0.07)]
    static let bones: [(Int,Int)] = [(0,1),(1,2),(1,3),(3,4),(4,5),(1,6),(6,7),(7,8),
        (0,9),(9,10),(10,11),(0,12),(12,13),(13,14)]
    static let links: [Link] = (bones + [(3,6),(9,12),(0,3),(0,6),(3,2),(6,2)]).map {
        Link(a:$0.0,b:$0.1,length:length(rest[$0.0]-rest[$0.1]))
    }
    private(set) var points: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    private var accumulator: Float = 0
    let floor: Float
    let obstacles: [Obstacle]
    let low: SIMD3<Float>, high: SIMD3<Float>
    private(set) var elapsed: Float = 0
    static func length(_ v: SIMD3<Float>) -> Float { sqrt(v.x*v.x+v.y*v.y+v.z*v.z) }
    init(offset: SIMD3<Float> = .zero, impulse: SIMD3<Float>, floor: Float = 0,
         low: SIMD3<Float> = SIMD3(-3.3,-10,-3.8), high: SIMD3<Float> = SIMD3(3.3,5,3.1), obstacles: [Obstacle] = []) {
        self.floor = floor; self.low = low; self.high = high; self.obstacles = obstacles
        points = Self.rest.map { $0+offset }
        let safe = [impulse.x,impulse.y,impulse.z].allSatisfy { $0.isFinite } ? impulse : .zero
        let velocity = safe * min(1,6/max(0.001,Self.length(safe)))
        previous = points.enumerated().map { index,p in
            let twist = SIMD3<Float>(index % 2 == 0 ? 0.15 : -0.15,0,Float(index % 3)*0.06)
            return p-(velocity+twist)/120
        }
    }
    mutating func update(dt: Float) {
        guard dt.isFinite, dt>0 else { return }
        accumulator += min(dt,0.1)
        let step: Float = 1/120
        var iterations = 0
        while accumulator >= step && iterations < 12 {
            accumulator -= step; iterations += 1; elapsed += step
            for i in points.indices {
                let p = points[i]
                let velocity = (p-previous[i])*0.994
                points[i] += velocity + SIMD3(0,-9.8*step*step,0)
                previous[i] = p
            }
            for _ in 0..<10 {
                for link in Self.links {
                    let delta = points[link.b]-points[link.a], d = Self.length(delta)
                    guard d>0.00001 else { continue }
                    let correction = delta*((d-link.length)/d*0.5)
                    points[link.a] += correction; points[link.b] -= correction
                }
                for i in points.indices {
                    let radius: Float = i == 2 ? 0.15 : (i<2 ? 0.12 : 0.065)
                    points[i].x = min(high.x-radius,max(low.x+radius,points[i].x))
                    points[i].z = min(high.z-radius,max(low.z+radius,points[i].z))
                    points[i].y = min(high.y-radius,points[i].y)
                    for box in obstacles {
                        let lo = box.low-SIMD3<Float>(repeating:radius), hi = box.high+SIMD3<Float>(repeating:radius)
                        let p = points[i]
                        guard p.x>lo.x && p.x<hi.x && p.y>lo.y && p.y<hi.y && p.z>lo.z && p.z<hi.z else { continue }
                        let faces: [(Float,Int,Float)] = [(p.x-lo.x,0,lo.x),(hi.x-p.x,0,hi.x),
                            (p.y-lo.y,1,lo.y),(hi.y-p.y,1,hi.y),(p.z-lo.z,2,lo.z),(hi.z-p.z,2,hi.z)]
                        if let face = faces.min(by: { $0.0<$1.0 }) { points[i][face.1] = face.2 }
                    }
                    if points[i].y < floor+radius {
                        points[i].y = floor+radius
                        previous[i].y = points[i].y
                        previous[i].x += (points[i].x-previous[i].x)*0.35
                        previous[i].z += (points[i].z-previous[i].z)*0.35
                    }
                }
            }
        }
        if iterations == 12 { accumulator = 0 }
    }
}
