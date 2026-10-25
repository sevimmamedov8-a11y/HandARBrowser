import SceneKit
import UIKit
import simd

/// Original, lightweight models with bevels, layered materials and real silhouettes.
enum SecurityModels {
    static func material(_ color: UIColor, metal: CGFloat = 0, rough: CGFloat = 0.45) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .physicallyBased
        m.diffuse.contents = color; m.metalness.contents = metal; m.roughness.contents = rough
        return m
    }
    @discardableResult static func box(_ parent: SCNNode, _ size: SIMD3<Float>, _ at: SIMD3<Float>, _ m: SCNMaterial, bevel: CGFloat = 0.01) -> SCNNode {
        let g = SCNBox(width:CGFloat(size.x),height:CGFloat(size.y),length:CGFloat(size.z),chamferRadius:bevel)
        g.chamferSegmentCount = 2; g.firstMaterial = m
        let n = SCNNode(geometry:g); n.simdPosition = at; parent.addChildNode(n); return n
    }
    @discardableResult static func cylinder(_ parent: SCNNode, radius: CGFloat, height: CGFloat, at: SIMD3<Float>, material: SCNMaterial) -> SCNNode {
        let g = SCNCylinder(radius:radius,height:height); g.radialSegmentCount = 16; g.firstMaterial = material
        let n = SCNNode(geometry:g); n.simdPosition = at; parent.addChildNode(n); return n
    }
    @discardableResult static func ring(_ parent: SCNNode, radius: CGFloat, pipe: CGFloat, at: SIMD3<Float>, material: SCNMaterial) -> SCNNode {
        let g = SCNTorus(ringRadius:radius,pipeRadius:pipe); g.ringSegmentCount = 16; g.pipeSegmentCount = 6; g.firstMaterial = material
        let n = SCNNode(geometry:g); n.simdPosition = at; parent.addChildNode(n); return n
    }
    static func make(_ kind: SecurityGoods) -> SCNNode {
        let n = SCNNode()
        let dark = material(UIColor(white:0.065,alpha:1),rough:0.58)
        let metal = material(UIColor(white:0.65,alpha:1),metal:0.8,rough:0.25)
        let gold = material(UIColor(red:0.86,green:0.61,blue:0.19,alpha:1),metal:0.85,rough:0.24)
        let teal = material(UIColor(red:0.08,green:0.48,blue:0.46,alpha:1))
        switch kind {
        case .chain:
            for i in 0..<24 {
                let angle = Float(i)/24 * Float.pi * 2
                let p = SIMD3<Float>(sin(angle)*0.13,-cos(angle)*0.11,cos(angle)*0.018)
                let link = ring(n,radius:0.013,pipe:0.003,at:p,material:gold)
                link.eulerAngles.x = .pi/2; link.eulerAngles.y = i%2 == 0 ? 0 : .pi/3
            }
            let pendant = box(n,SIMD3(0.035,0.05,0.008),SIMD3(0,-0.135,0.01),gold,bevel:0.007)
            pendant.eulerAngles.z = .pi/8
        case .camera:
            box(n,SIMD3(0.22,0.14,0.08),.zero,dark,bevel:0.018)
            box(n,SIMD3(0.065,0.17,0.09),SIMD3(0.085,0,0.005),teal)
            let lens = cylinder(n,radius:0.053,height:0.085,at:SIMD3(-0.02,0,0.065),material:dark); lens.eulerAngles.x = .pi/2
            let rim = ring(n,radius:0.046,pipe:0.006,at:SIMD3(-0.02,0,0.11),material:metal); rim.eulerAngles.x = .pi/2
            let glass = cylinder(n,radius:0.039,height:0.003,at:SIMD3(-0.02,0,0.113),material:material(UIColor(red:0.09,green:0.20,blue:0.34,alpha:1),metal:0.4,rough:0.12)); glass.eulerAngles.x = .pi/2
            box(n,SIMD3(0.05,0.035,0.045),SIMD3(0,0.085,-0.01),dark)
            cylinder(n,radius:0.017,height:0.015,at:SIMD3(0.065,0.08,0),material:metal)
            box(n,SIMD3(0.13,0.085,0.004),SIMD3(-0.02,0,-0.043),material(UIColor(white:0.16,alpha:1)),bevel:0.006)
        case .skateboard:
            box(n,SIMD3(0.21,0.70,0.025),.zero,material(UIColor(red:0.55,green:0.21,blue:0.1,alpha:1)),bevel:0.012)
            box(n,SIMD3(0.19,0.66,0.006),SIMD3(0,0,0.016),dark,bevel:0.003)
            for y in [Float(-0.23),0.23] {
                box(n,SIMD3(0.17,0.025,0.035),SIMD3(0,y,-0.04),metal)
                for x in [Float(-0.10),0.10] {
                    let wheel = cylinder(n,radius:0.035,height:0.028,at:SIMD3(x,y,-0.065),material:material(UIColor(white:0.85,alpha:1)))
                    wheel.eulerAngles.z = .pi/2
                }
            }
            for y in [Float(-0.12),0,0.12] { box(n,SIMD3(0.10,0.035,0.003),SIMD3(0,y,-0.016),teal,bevel:0.001) }
        case .headphones:
            let band = ring(n,radius:0.095,pipe:0.012,at:SIMD3(0,0.025,0),material:dark)
            band.eulerAngles.x = .pi/2; band.scale = SCNVector3(1,1,1.15)
            for side in [Float(-1),1] {
                box(n,SIMD3(0.045,0.10,0.07),SIMD3(side*0.095,-0.035,0),metal,bevel:0.017)
                box(n,SIMD3(0.018,0.085,0.065),SIMD3(side*0.07,-0.035,0),dark,bevel:0.008)
            }
        case .speaker:
            box(n,SIMD3(0.23,0.32,0.13),.zero,teal,bevel:0.028)
            box(n,SIMD3(0.20,0.28,0.008),SIMD3(0,0,0.07),dark,bevel:0.004)
            for y in [Float(-0.07),0.065] {
                let grille = ring(n,radius:0.056,pipe:0.006,at:SIMD3(0,y,0.078),material:metal); grille.eulerAngles.x = .pi/2
                let cone = cylinder(n,radius:0.045,height:0.004,at:SIMD3(0,y,0.077),material:dark); cone.eulerAngles.x = .pi/2
            }
            box(n,SIMD3(0.12,0.015,0.04),SIMD3(0,0.185,0),dark)
            for x in [Float(-0.065),0.065] { box(n,SIMD3(0.015,0.045,0.04),SIMD3(x,0.17,0),dark) }
        case .sealedCase:
            box(n,SIMD3(0.26,0.19,0.11),.zero,dark,bevel:0.018)
            box(n,SIMD3(0.265,0.008,0.115),.zero,metal,bevel:0.003)
            for x in [Float(-0.08),0.08] { box(n,SIMD3(0.025,0.04,0.012),SIMD3(x,0.015,0.06),metal,bevel:0.004) }
            box(n,SIMD3(0.09,0.025,0.035),SIMD3(0,0.125,0),dark)
            for x in [Float(-0.055),0.055] { box(n,SIMD3(0.02,0.04,0.035),SIMD3(x,0.105,0),metal) }
        case .bottle:
            let green = material(UIColor(red:0.10,green:0.34,blue:0.22,alpha:1),metal:0.15,rough:0.2)
            cylinder(n,radius:0.038,height:0.17,at:SIMD3(0,0,0),material:green)
            let neck = SCNCone(topRadius:0.016,bottomRadius:0.038,height:0.05); neck.radialSegmentCount = 16; neck.firstMaterial = green
            let shoulder = SCNNode(geometry:neck); shoulder.position.y = 0.11; n.addChildNode(shoulder)
            cylinder(n,radius:0.016,height:0.07,at:SIMD3(0,0.17,0),material:green)
            cylinder(n,radius:0.018,height:0.025,at:SIMD3(0,0.211,0),material:gold)
            cylinder(n,radius:0.0385,height:0.075,at:SIMD3(0,0.005,0),material:material(UIColor(red:0.85,green:0.68,blue:0.34,alpha:1)))
            box(n,SIMD3(0.035,0.045,0.003),SIMD3(0,0.005,0.039),dark,bevel:0.003)
        }
        if kind == .bottle { for child in n.childNodes { child.position.y -= 0.069 } }
        return n.flattenedClone()
    }
    static func tool(_ index: Int) -> SCNNode {
        if index == 4 { return make(.bottle) }
        let n = SCNNode(), dark = material(UIColor(white:0.08,alpha:1)), silver = material(UIColor(white:0.7,alpha:1),metal:0.7)
        let accent = material(index == 2 ? .systemBlue : (index == 3 ? .systemYellow : .systemTeal))
        box(n,SIMD3(0.07,0.035,0.16),.zero,dark)
        box(n,SIMD3(0.055,0.008,0.065),SIMD3(0,0.024,-0.015),accent,bevel:0.004)
        for x in [Float(-0.018),0,0.018] { cylinder(n,radius:0.004,height:0.006,at:SIMD3(x,0.023,0.045),material:silver) }
        if index >= 2 {
            box(n,SIMD3(0.035,0.09,0.045),SIMD3(0,-0.055,0.04),accent)
            let tip = cylinder(n,radius:0.018,height:0.035,at:SIMD3(0,0,-0.09),material:silver); tip.eulerAngles.x = .pi/2
        } else {
            let probe = cylinder(n,radius:index == 0 ? 0.038 : 0.012,height:0.045,at:SIMD3(0,0,-0.09),material:silver); probe.eulerAngles.x = .pi/2
        }
        return n.flattenedClone()
    }
}

final class SecurityRagdollView {
    let root = SCNNode()
    private let segments: [SCNNode]
    private let head: SCNNode
    init(skin: SCNMaterial, cloth: SCNMaterial, headModel: SCNNode) {
        head = headModel
        var nodes: [SCNNode] = []
        for (index,bone) in SecurityRagdoll.bones.enumerated() {
            let length = SecurityRagdoll.length(SecurityRagdoll.rest[bone.1]-SecurityRagdoll.rest[bone.0])
            let radius: Float = index == 0 ? 0.15 : (index == 1 ? 0.065 : 0.055)
            let g = SCNCapsule(capRadius:CGFloat(radius),height:CGFloat(length+radius))
            g.radialSegmentCount = 10; g.heightSegmentCount = 1; g.firstMaterial = cloth
            let node = SCNNode(geometry:g); root.addChildNode(node); nodes.append(node)
        }
        segments = nodes; root.addChildNode(head)
        for index in [5,8] {
            let g = SCNSphere(radius:0.065); g.segmentCount = 10; g.firstMaterial = skin
            let hand = SCNNode(geometry:g); hand.name = String(index); root.addChildNode(hand)
        }
        for index in [11,14] {
            let shoe = SecurityModels.box(root,SIMD3(0.13,0.09,0.23),.zero,SecurityModels.material(UIColor(white:0.08,alpha:1)),bevel:0.02)
            shoe.name = String(index)
            SecurityModels.box(shoe,SIMD3(0.135,0.02,0.235),SIMD3(0,-0.04,0),SecurityModels.material(UIColor(white:0.85,alpha:1)),bevel:0.005)
        }
    }
    func update(_ state: SecurityRagdoll) {
        for (index,bone) in SecurityRagdoll.bones.enumerated() {
            let a = state.points[bone.0], b = state.points[bone.1], delta = b-a
            segments[index].simdPosition = (a+b)*0.5
            if simd_length(delta)>0.001 { segments[index].simdOrientation = simd_quatf(from:SIMD3(0,1,0),to:simd_normalize(delta)) }
        }
        head.simdPosition = state.points[2]
        let neck = state.points[2]-state.points[1]
        if simd_length(neck)>0.001 { head.simdOrientation = simd_quatf(from:SIMD3(0,1,0),to:simd_normalize(neck)) }
        for child in root.childNodes {
            if let name = child.name, let index = Int(name) { child.simdPosition = state.points[index] }
        }
    }
}
