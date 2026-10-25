import Foundation

struct NeonFlightSteering {
    private var center=SIMD2<Double>.zero
    private var last: (angle:SIMD2<Double>,stamp:Double)?
    private var stableSince: Double?
    private var target=SIMD2<Float>.zero
    private(set) var control=SIMD2<Float>.zero
    private(set) var safe=false
    static func wrap(_ angle:Double)->Double { atan2(sin(angle),cos(angle)) }
    mutating func calibrate(yaw:Double,pitch:Double) {center=SIMD2(yaw,pitch);control = .zero;target = .zero}
    mutating func update(yaw:Double,pitch:Double,stamp:Double,now:Double,ready:Bool,dt:Double) {
        guard ready,yaw.isFinite,pitch.isFinite,stamp.isFinite,now.isFinite,now>=stamp,now-stamp<=0.2 else {lose();return}
        let angle=SIMD2(yaw,pitch)
        if let old=last {
            let gap=stamp-old.stamp
            if gap<0 || gap>0.2 {lose()}
            else if gap>0 {
                let travel=hypot(Self.wrap(yaw-old.angle.x),pitch-old.angle.y)
                if travel/gap>7 {lose();last=(angle,stamp);return}
            }
        }
        if last?.stamp != stamp {
            last=(angle,stamp)
            if stableSince == nil {stableSince=now}
            safe=now-(stableSince ?? now)>=0.3
            func axis(_ value:Double,_ full:Double)->Float {
                let magnitude=max(0,abs(value)-0.035)/(full-0.035)
                return Float(min(1,magnitude)*(value<0 ? -1:1))
            }
            target=SIMD2(axis(Self.wrap(yaw-center.x),0.35),axis(pitch-center.y,0.24))
        }
        if safe {control += (target-control)*Float(1-exp(-max(0,min(dt,0.1))/0.09))}
        else {control = .zero}
    }
    private mutating func lose() {safe=false;last=nil;stableSince=nil;target = .zero;control = .zero}
}

struct NeonFlightItem {
    enum Kind:Int,CaseIterable {case ring,energy,gate,asteroid}
    let id:Int,kind:Kind
    let lane:SIMD2<Float>
    var distance:Float
    let phase:Float
    func center(at time:Double)->SIMD2<Float> {
        let sway:Float = kind == .gate ? 0.22 : (kind == .asteroid ? 0.35:0)
        return lane+SIMD2(sin(Float(time)*0.8+phase)*sway,cos(Float(time)*0.65+phase)*sway*0.5)
    }
}

struct NeonFlightRun {
    enum Event:Equatable {case ring,energy,shield,impact,gameOver}
    private(set) var items:[NeonFlightItem]=[]
    private(set) var position=SIMD2<Float>.zero
    private(set) var distance:Float=0,time=0.0
    private(set) var score=0,hull=3,shields=0,energy=0,rings=0,combo=0
    private(set) var ended=false
    private(set) var events:[Event]=[]
    private var nextID=0,row=0,nextRow:Float=12
    private var accumulator=0.0,invulnerable=0.0
    private var seed:UInt64
    var biome:Int {Int(distance/250)%3}
    var speed:Float {min(9,5+distance/180)}
    init(seed:UInt64=1) {self.seed=seed;items.reserveCapacity(32);fill()}
    private mutating func random()->Float {
        seed=seed &* 6364136223846793005 &+ 1442695040888963407
        return Float((seed>>40)&0xFFFFFF)/Float(0xFFFFFF)
    }
    private mutating func add(_ kind:NeonFlightItem.Kind,_ lane:SIMD2<Float>,_ at:Float) {
        items.append(NeonFlightItem(id:nextID,kind:kind,lane:lane,distance:at,phase:random()*6.28));nextID+=1
    }
    private mutating func fill() {
        while nextRow-distance<62 {
            let target=SIMD2<Float>(sin(Float(row)*0.7)*1.65,sin(Float(row)*0.43)*0.75)
            let ahead=nextRow-distance
            add(.ring,target,ahead)
            if row%2==1 {add(.energy,target+SIMD2(0.25,0.12),ahead+2.5)}
            if row>=4 && row%2==0 {add(.gate,target,ahead)}
            if row>=5 && row%2==1 {
                let side:Float=target.x>=0 ? -1:1
                add(.asteroid,SIMD2(side*1.8,-target.y),ahead-1.5)
            }
            row+=1;nextRow+=9
        }
    }
    mutating func advance(dt:Double,control:SIMD2<Float>) {
        events.removeAll(keepingCapacity:true)
        guard !ended,dt.isFinite,dt>0,control.x.isFinite,control.y.isFinite else {return}
        accumulator+=min(dt,0.1)
        let step=1.0/120.0
        var steps=0
        while accumulator+1e-10>=step && steps<12 && !ended {
            accumulator-=step;steps+=1;simulate(step,control)
        }
        if steps==12 {accumulator=0}
    }
    private mutating func simulate(_ dt:Double,_ control:SIMD2<Float>) {
        time+=dt;invulnerable=max(0,invulnerable-dt)
        let previous=position
        position += SIMD2(max(-1,min(1,control.x)),max(-1,min(1,control.y)))*Float(dt)*2.5
        position.x=max(-2.7,min(2.7,position.x));position.y=max(-1.5,min(1.5,position.y))
        let travel=speed*Float(dt);distance+=travel
        for index in items.indices {
            let before=items[index].distance
            items[index].distance-=travel
            guard before>0,items[index].distance<=0 else {continue}
            let t=max(0,min(1,before/travel)),point=previous+(position-previous)*t
            let delta=point-items[index].center(at:time)
            let d=sqrt(delta.x*delta.x+delta.y*delta.y)
            switch items[index].kind {
            case .ring:
                if d<=0.70 {rings+=1;combo+=1;score+=100+min(100,(combo-1)*10);events.append(.ring)}
                else {combo=0}
            case .energy:
                if d<=0.6 {
                    energy+=1;score+=25;events.append(.energy)
                    if energy>=3 {energy=0;shields=min(3,shields+1);events.append(.shield)}
                }
            case .gate:
                if abs(delta.x)>0.87 || abs(delta.y)>0.57 {hit()}
            case .asteroid:
                if d<0.7 {hit()}
            }
        }
        items.removeAll {$0.distance < -3}
        fill()
    }
    private mutating func hit() {
        guard invulnerable<=0,!ended else {return}
        invulnerable=1.2;combo=0
        if shields>0 {shields-=1;events.append(.shield)}
        else {hull-=1;events.append(.impact)}
        if hull==0 {ended=true;events.append(.gameOver)}
    }
}

enum NeonFlightProgress {
    static let key="neonFlight.best.v1"
    static func best(_ defaults:UserDefaults = .standard)->Int {max(0,defaults.integer(forKey:key))}
    static func ships(_ best:Int)->Int {best>=1500 ? 3:(best>=500 ? 2:1)}
    static func record(_ score:Int,defaults:UserDefaults = .standard) {
        if score>best(defaults) {defaults.set(score,forKey:key)}
    }
}
