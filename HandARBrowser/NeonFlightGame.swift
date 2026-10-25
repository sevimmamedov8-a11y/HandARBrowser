import AVFoundation
import SceneKit
import UIKit
import simd

private final class FlightSounds {
    private var players:[String:AVAudioPlayer]=[:]
    func prepare() {
        for (key,name,folder) in [("ring","UIConfirm",Optional<String>.none),("hit","tm_hit","TimeMotionSounds"),("shield","tm_win","TimeMotionSounds")] {
            let url=Bundle.main.url(forResource:name,withExtension:"wav",subdirectory:folder)
            if let url,let player=try? AVAudioPlayer(contentsOf:url) {player.volume=0.45;player.prepareToPlay();players[key]=player}
        }
    }
    func play(_ key:String) {players[key]?.currentTime=0;players[key]?.play()}
    func stop() {for player in players.values {player.stop()}}
}

private final class FlightLabel:SCNNode {
    private var text=""
    func set(_ value:String,width:Float) {
        guard value != text else {return};text=value
        let font=UIFont.systemFont(ofSize:36,weight:.semibold)
        let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:UIColor.white]
        let rect=(value as NSString).boundingRect(with:CGSize(width:1000,height:300),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attrs,context:nil)
        let size=CGSize(width:max(1,ceil(rect.width)+20),height:max(1,ceil(rect.height)+12))
        let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=false
        let image=UIGraphicsImageRenderer(size:size,format:format).image {_ in
            (value as NSString).draw(in:CGRect(x:10,y:6,width:size.width-20,height:size.height-12),withAttributes:attrs)
        }
        let plane=SCNPlane(width:CGFloat(width),height:CGFloat(width)*size.height/size.width)
        let material=SCNMaterial();material.lightingModel = .constant;material.isDoubleSided=true;material.diffuse.contents=image
        plane.firstMaterial=material;geometry=plane
    }
}

final class NeonFlightGame {
    private enum Mode {case menu,countdown,flying,paused,over}
    private struct Visual {let kind:NeonFlightItem.Kind,node:SCNNode;var id:Int?}
    var onExit:(()->Void)?
    private(set) var isRunning=false
    private var mode=Mode.menu
    private let root=SCNNode(),world=SCNNode(),shipRoot=SCNNode(),shieldNode=SCNNode()
    private let stats=FlightLabel(),notice=FlightLabel(),bestLabel=FlightLabel()
    private var buttons:[SCNNode]=[],buttonLabels:[FlightLabel]=[]
    private var frames:[SCNNode]=[],stationShells:[SCNNode]=[],spaceRocks:[SCNNode]=[],stars:[SCNNode]=[],ships:[SCNNode]=[]
    private var visuals:[Visual]=[]
    private var starSeeds:[SIMD3<Float>]=[]
    private var gate=ReleaseClickGate<Int>()
    private let progress=DwellProgressRing()
    private let sounds=FlightSounds()
    private var steering=NeonFlightSteering(),run=NeonFlightRun()
    private var basisForward=SIMD3<Float>(0,0,-1),basisRight=SIMD3<Float>(1,0,0)
    private var last:Double?,lastHUD = -Double.infinity,countdown=3.0
    private var selectedShip=0,record=0
    private var newRun=true
    private var built=false
    private(set) var trackingSafe=false

    private func material(_ color:UIColor)->SCNMaterial {
        let m=SCNMaterial();m.lightingModel = .constant;m.diffuse.contents=color;return m
    }
    @discardableResult private func box(_ parent:SCNNode,_ size:SIMD3<Float>,_ point:SIMD3<Float>,_ m:SCNMaterial)->SCNNode {
        let shape=SCNBox(width:CGFloat(size.x),height:CGFloat(size.y),length:CGFloat(size.z),chamferRadius:0.012)
        shape.chamferSegmentCount=1;shape.firstMaterial=m
        let n=SCNNode(geometry:shape);n.simdPosition=point;parent.addChildNode(n);return n
    }
    private func makeItem(_ kind:NeonFlightItem.Kind)->SCNNode {
        let n=SCNNode()
        let cyan=material(UIColor(red:0.1,green:0.85,blue:1,alpha:1))
        switch kind {
        case .ring:
            let shape=SCNTorus(ringRadius:0.80,pipeRadius:0.035);shape.ringSegmentCount=24;shape.pipeSegmentCount=6;shape.firstMaterial=cyan
            let rim=SCNNode(geometry:shape);rim.eulerAngles.x = .pi/2;n.addChildNode(rim)
        case .energy:
            let shape=SCNSphere(radius:0.15);shape.segmentCount=8;shape.firstMaterial=material(UIColor(red:0.7,green:1,blue:0.3,alpha:1))
            n.addChildNode(SCNNode(geometry:shape))
            let shape2=SCNTorus(ringRadius:0.24,pipeRadius:0.015);shape2.ringSegmentCount=16;shape2.pipeSegmentCount=4;shape2.firstMaterial=cyan;n.addChildNode(SCNNode(geometry:shape2))
        case .gate:
            let dark=material(UIColor(red:0.11,green:0.03,blue:0.12,alpha:1)),red=material(UIColor(red:1,green:0.22,blue:0.4,alpha:1))
            for side in [Float(-1),1] {
                box(n,SIMD3(4,7,0.16),SIMD3(side*3.1,0,0),dark)
                box(n,SIMD3(0.055,1.6,0.20),SIMD3(side*1.1,0,0),red)
                box(n,SIMD3(2.2,3,0.16),SIMD3(0,side*2.3,0),dark)
                box(n,SIMD3(2.2,0.055,0.20),SIMD3(0,side*0.8,0),red)
            }
        case .asteroid:
            let shape=SCNSphere(radius:0.48);shape.segmentCount=7;shape.firstMaterial=material(UIColor(red:0.46,green:0.32,blue:0.58,alpha:1))
            let rock=SCNNode(geometry:shape);rock.scale=SCNVector3(1,0.8,1.1);n.addChildNode(rock)
            box(n,SIMD3(0.10,0.55,0.12),SIMD3(0.30,0,0),cyan)
        }
        return n
    }
    private func build() {
        guard !built else {return};built=true;root.addChildNode(world)
        let fill=SCNLight();fill.type = .ambient;fill.intensity=350
        let fillNode=SCNNode();fillNode.light=fill;root.addChildNode(fillNode)
        let key=SCNLight();key.type = .directional;key.intensity=800;key.castsShadow=false
        let lamp=SCNNode();lamp.light=key;lamp.eulerAngles=SCNVector3(-0.7,-0.6,0);root.addChildNode(lamp)
        let line=material(UIColor(red:0.08,green:0.28,blue:0.35,alpha:1))
        for _ in 0..<12 {
            let frame=SCNNode()
            for side in [Float(-1),1] {
                box(frame,SIMD3(6.5,0.025,0.025),SIMD3(0,side*2.2,0),line)
                box(frame,SIMD3(0.025,4.4,0.025),SIMD3(side*3.25,0,0),line)
            }
            let shell=SCNNode(),panel=material(UIColor(red:0.035,green:0.055,blue:0.10,alpha:1))
            for side in [Float(-1),1] {
                box(shell,SIMD3(0.12,4.4,5.8),SIMD3(side*3.3,0,0),panel)
                box(shell,SIMD3(6.6,0.12,5.8),SIMD3(0,side*2.25,0),panel)
                box(shell,SIMD3(0.02,1.25,2.4),SIMD3(side*3.22,0.35,0),line)
            }
            let merged=shell.flattenedClone();frame.addChildNode(merged);stationShells.append(merged)
            world.addChildNode(frame);frames.append(frame)
        }
        let starShape=SCNSphere(radius:0.025);starShape.segmentCount=4;starShape.firstMaterial=material(.white)
        for index in 0..<64 {
            let node=SCNNode(geometry:starShape);world.addChildNode(node);stars.append(node)
            starSeeds.append(SIMD3(Float((index*37)%101)/101*26-13,Float((index*53)%97)/97*16-8,Float(index)*0.93))
        }
        let rockMaterial=material(UIColor(red:0.24,green:0.19,blue:0.31,alpha:1));rockMaterial.lightingModel = .lambert
        let rockShape=SCNSphere(radius:1);rockShape.segmentCount=7;rockShape.firstMaterial=rockMaterial
        for index in 0..<18 {
            let rock=SCNNode(geometry:rockShape),size=Float(0.6)+Float(index%5)*0.28
            rock.scale=SCNVector3(size,size*0.8,size*1.1);world.addChildNode(rock);spaceRocks.append(rock)
        }
        for kind in NeonFlightItem.Kind.allCases {
            let count=kind == .gate ? 8:12
            for _ in 0..<count {let node=makeItem(kind);node.isHidden=true;world.addChildNode(node);visuals.append(Visual(kind:kind,node:node,id:nil))}
        }
        for index in 0..<3 {
            let ship=SCNNode(),gray=material(UIColor(white:0.22,alpha:1))
            let colors:[UIColor]=[.systemCyan,UIColor(red:0.8,green:0.4,blue:1,alpha:1),UIColor(red:1,green:0.7,blue:0.25,alpha:1)]
            let accent=material(colors[index])
            let nose=SCNCone(topRadius:0.015,bottomRadius:0.13,height:0.58);nose.radialSegmentCount=8;nose.firstMaterial=gray
            let tip=SCNNode(geometry:nose);tip.eulerAngles.x = -.pi/2;ship.addChildNode(tip)
            for side in [Float(-1),1] {
                let wing=box(ship,SIMD3(0.35+Float(index)*0.06,0.035,0.30),SIMD3(side*0.24,0,0.10),gray);wing.eulerAngles.z=side*0.15
                box(ship,SIMD3(0.24,0.018,0.04),SIMD3(side*0.27,0.025,0.12),accent)
                box(ship,SIMD3(0.045,0.06,0.13),SIMD3(side*0.16,-0.01,0.33),accent)
            }
            box(ship,SIMD3(0.09,0.055,0.16),SIMD3(0,0.08,0.02),accent)
            shipRoot.addChildNode(ship);ships.append(ship)
        }
        shipRoot.position=SCNVector3(0,-0.42,-1.95);root.addChildNode(shipRoot)
        let shield=SCNTorus(ringRadius:0.62,pipeRadius:0.014);shield.ringSegmentCount=28;shield.pipeSegmentCount=4;shield.firstMaterial=material(.systemCyan)
        shieldNode.geometry=shield;shieldNode.eulerAngles.x = .pi/2;shieldNode.position=SCNVector3(0,-0.25,-2);root.addChildNode(shieldNode)
        stats.position=SCNVector3(0,-0.95,-3.2);bestLabel.position=SCNVector3(0,0.92,-3.4);notice.position=SCNVector3(0,0.1,-3.2)
        for label in [stats,bestLabel,notice] {root.addChildNode(label)}
        for _ in 0..<3 {
            let node=SCNNode(),m=material(UIColor(red:0.08,green:0.16,blue:0.23,alpha:1))
            box(node,SIMD3(0.64,0.18,0.025),.zero,m)
            let label=FlightLabel();label.position.z=0.018;node.addChildNode(label);root.addChildNode(node)
            buttons.append(node);buttonLabels.append(label)
        }
        root.addChildNode(progress)
    }
    func start(in scene:SCNScene,head:SCNNode) {
        guard !isRunning else {return};build();isRunning=true;scene.rootNode.addChildNode(root)
        record=NeonFlightProgress.best();selectedShip=min(UserDefaults.standard.integer(forKey:"neonFlight.ship"),NeonFlightProgress.ships(record)-1);selectedShip=max(0,selectedShip)
        run=NeonFlightRun();mode = .menu;last=nil;lastHUD = -.infinity;steering=NeonFlightSteering();gate.cancel();progress.isHidden=true
        align(head);sounds.prepare();render()
    }
    private func align(_ head:SCNNode) {
        let c=head.simdWorldTransform.columns.2
        let flat=SIMD3<Float>(-c.x,0,-c.z)
        basisForward=simd_length(flat)>0.001 ? simd_normalize(flat):SIMD3(0,0,-1)
        basisRight=simd_cross(basisForward,SIMD3(0,1,0))
        root.simdPosition=head.simdWorldPosition
        root.simdOrientation=simd_quatf(simd_float3x3(columns:(basisRight,SIMD3(0,1,0),-basisForward)))
    }
    func stop() {
        guard isRunning else {return};NeonFlightProgress.record(run.score);record=max(record,run.score)
        isRunning=false;root.removeFromParentNode();gate.cancel();progress.isHidden=true;sounds.stop();last=nil
    }
    func recenter(head:SCNNode) {
        if mode == .flying || mode == .countdown {mode = .paused}
        align(head);steering=NeonFlightSteering();gate.cancel();lastHUD = -.infinity
    }
    func update(now:Double,head:SCNNode,stamp:Double,ready:Bool) {
        guard isRunning,now.isFinite else {return}
        let elapsed=now-(last ?? now),dt=min(0.1,max(0,elapsed));last=now
        root.simdPosition=head.simdWorldPosition
        let c=head.simdWorldTransform.columns.2,dir=SIMD3<Float>(-c.x,-c.y,-c.z)
        let local=SIMD3(simd_dot(dir,basisRight),dir.y,simd_dot(dir,basisForward))
        let yaw=Double(atan2(local.x,local.z)),pitch=Double(asin(max(-1,min(1,local.y))))
        steering.update(yaw:yaw,pitch:pitch,stamp:stamp,now:now,ready:ready && elapsed>=0 && elapsed<0.25,dt:dt)
        trackingSafe=steering.safe
        if !trackingSafe && (mode == .flying || mode == .countdown) {mode = .paused;sounds.stop();gate.cancel()}
        if mode == .flying && (abs(yaw)>1.15 || abs(pitch)>0.75) {mode = .paused;gate.cancel()}
        layoutButtons()
        var target:Int?
        if trackingSafe {
            for index in buttons.indices where !buttons[index].isHidden {
                let p=buttons[index].simdPosition,direction=SIMD3(local.x,local.y,-local.z)
                let t=simd_dot(p,direction)
                if t>0,simd_length(direction*t-p)<0.24 {target=index;break}
            }
        }
        let clicked=gate.update(target:target,down:false,allowBegin:false,dwell:true,at:now)
        progress.show(on:target.map {buttons[$0]},progress:gate.dwellProgress)
        if let clicked {action(clicked,head:head);if !isRunning{return}}
        if trackingSafe {
            if mode == .countdown {
                steering.calibrate(yaw:yaw,pitch:pitch);countdown-=dt
                if countdown<=0 {if newRun {run=NeonFlightRun(seed:UInt64.random(in:1...UInt64.max))};mode = .flying}
            } else if mode == .flying && target == nil {
                run.advance(dt:dt,control:steering.control)
                for event in run.events {
                    switch event {
                    case .ring,.energy:sounds.play("ring")
                    case .shield:sounds.play("shield")
                    case .impact:sounds.play("hit")
                    case .gameOver:NeonFlightProgress.record(run.score);record=max(record,run.score);mode = .over
                    }
                }
            }
        }
        render()
        if now-lastHUD>=0.2 {hud();lastHUD=now}
    }
    private func action(_ id:Int,head:SCNNode) {
        gate.cancel();lastHUD = -.infinity
        if id==2 {onExit?();return}
        if id==1 {
            if mode == .paused {recenter(head:head)}
            else {selectedShip=(selectedShip+1)%NeonFlightProgress.ships(record);UserDefaults.standard.set(selectedShip,forKey:"neonFlight.ship")}
        } else if mode == .flying {mode = .paused;sounds.stop()}
        else {newRun=mode != .paused;countdown=3;mode = .countdown}
        sounds.play("ring")
    }
    private func layoutButtons() {
        for index in buttons.indices {
            buttons[index].isHidden = mode == .countdown || (mode == .flying && index != 0)
            buttons[index].simdPosition=mode == .flying ? SIMD3(2.1,-0.9,-3):SIMD3(Float(index-1)*0.80,-0.72,-3)
        }
        buttonLabels[0].set(mode == .flying ? "Пауза":(mode == .paused ? "Продолжить":"Играть"),width:0.54)
        buttonLabels[1].set(mode == .paused ? "Центр":"Корабль \(selectedShip+1)",width:0.54)
        buttonLabels[2].set("Выход",width:0.46)
    }
    private func render() {
        let distance=run.distance,position=run.position
        for (i,node) in frames.enumerated() {
            let d=(Float(i)*6-distance.truncatingRemainder(dividingBy:6))
            node.simdPosition=SIMD3(-position.x,-position.y,-d-4)
            node.isHidden=run.biome==1
            stationShells[i].isHidden=run.biome != 2
            node.scale=run.biome==2 ? SCNVector3(1.2,1.2,1):SCNVector3(1,1,1)
        }
        for (i,node) in stars.enumerated() {
            let seed=starSeeds[i]
            let z=(seed.z+distance*0.4).truncatingRemainder(dividingBy:65)
            node.simdPosition=SIMD3(seed.x-position.x*0.3,seed.y-position.y*0.3,z-70)
        }
        for (index,node) in spaceRocks.enumerated() {
            let side:Float=index%2==0 ? -1:1
            let x=side*(5.5+Float(index%4)*1.3)-position.x
            let z=(Float(index)*4.7+distance*0.6).truncatingRemainder(dividingBy:80)-85
            node.simdPosition=SIMD3(x,Float(index%5)-2-position.y,z)
            node.simdEulerAngles=SIMD3(Float(index)*0.8,Float(index)*0.3+Float(run.time)*0.02,0)
            node.isHidden=run.biome != 1
        }
        let live=Set(run.items.map { $0.id })
        for i in visuals.indices where visuals[i].id.map({!live.contains($0)}) ?? false {visuals[i].id=nil;visuals[i].node.isHidden=true}
        for item in run.items {
            var slot=visuals.firstIndex {$0.id==item.id}
            if slot == nil {slot=visuals.firstIndex {$0.id == nil && $0.kind==item.kind}}
            guard let i=slot else {continue};visuals[i].id=item.id
            let p=item.center(at:run.time)-position
            visuals[i].node.simdPosition=SIMD3(p.x,p.y,-item.distance-2)
            visuals[i].node.isHidden=item.distance<0
            if item.kind == .energy || item.kind == .asteroid {visuals[i].node.simdEulerAngles=SIMD3(Float(run.time)*0.4,Float(run.time)*0.6,0)}
        }
        shipRoot.eulerAngles.z = -steering.control.x*0.20
        shipRoot.eulerAngles.x = steering.control.y*0.08
        for index in ships.indices {ships[index].isHidden=index != selectedShip}
        shieldNode.isHidden=run.shields==0
    }
    private func hud() {
        stats.set("Очки \(run.score) · Корпус \(run.hull)/3\nЩит \(run.shields) · Энергия \(run.energy)/3",width:1.45)
        let names=["Неоновый тоннель","Астероиды","Космическая станция"]
        bestLabel.set(mode == .flying ? "\(names[run.biome]) · \(Int(run.distance)) м" : "\(names[run.biome])\nРекорд \(record)",width:1.45)
        let text:String
        if !trackingSafe {text="Смотри вперёд · настраиваю отслеживание"}
        else {
            switch mode {
            case .menu:text="НЕОНОВЫЙ ПОЛЁТ\nНебольшие повороты головы — управление\nСобирай кольца · энергия заряжает щит\nНовые корабли: 500 и 1500 очков"
            case .countdown:text="Смотри прямо · старт через \(max(1,Int(ceil(countdown))))"
            case .paused:text="ПАУЗА\nНаведи взгляд на «Продолжить»"
            case .over:text="ПОЛЁТ ОКОНЧЕН\n\(run.score) очков · \(run.rings) колец"
            case .flying:text=""
            }
        }
        notice.set(text,width:1.9);notice.isHidden=text.isEmpty
    }
}
