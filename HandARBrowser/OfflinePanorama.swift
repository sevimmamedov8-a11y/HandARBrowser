import Foundation
import SceneKit
import UIKit
import ImageIO
import simd

struct OfflinePanoramaAsset: Decodable {
    let id: String
    let title: String
    let filename: String
    let author: String
    let license: String
    let licenseURL: String
    let sourceURL: String
    let width: Int
    let height: Int
    let focusU: Double

    static func load(id: String, bundle: Bundle = .main) -> Self? {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "Panoramas"),
              let data = try? Data(contentsOf: url),
              let assets = try? JSONDecoder().decode([Self].self, from: data) else { return nil }
        return assets.first { $0.id == id && $0.width == $0.height * 2 && $0.height > 0 }
    }
}

// Image coordinates: u increases to the viewer's right, v=0 is the zenith.
// The photographed landmark (focusU) starts directly ahead. This is a photo
// sphere, not a 3D reconstruction: translation must never move us off-center.
enum PanoramaProjection {
    static func direction(u: Double, v: Double, focusU: Double) -> SIMD3<Float> {
        let longitude = (u - focusU) * 2 * Double.pi
        let latitude = (0.5 - v) * Double.pi
        let horizontal = cos(latitude)
        return SIMD3(Float(sin(longitude) * horizontal), Float(sin(latitude)),
                     Float(-cos(longitude) * horizontal))
    }
    static func yaw(forward: SIMD3<Float>, fallback: Float = 0) -> Float {
        guard forward.x.isFinite, forward.z.isFinite,
              forward.x * forward.x + forward.z * forward.z > 0.0001 else { return fallback }
        return atan2(-forward.x, -forward.z)
    }
}

final class OfflinePanorama {
    private let root = SCNNode()
    private let sphere = SCNNode()
    private let controls = SCNNode()
    private let title = CineText()
    private let credit = CineText()
    private let home = CineButton(title: "‹ Места", color: .darkGray, width: 0.42)
    private let center = CineButton(title: "Вперёд", color: .darkGray, width: 0.42)
    private let ring = DwellProgressRing()
    private var gate = ReleaseClickGate<Int>()
    private var generation = UUID()
    private var yaw: Float = 0
    private(set) var isRunning = false
    var onExit: (() -> Void)?
    var onRecenter: (() -> Void)?
    var onInteraction: (() -> Void)?

    init() {
        root.addChildNode(sphere)
        root.addChildNode(controls)
        controls.addChildNode(home.node)
        controls.addChildNode(center.node)
        controls.addChildNode(title)
        controls.addChildNode(credit)
        home.node.position = SCNVector3(-0.25, -0.42, -1.45)
        center.node.position = SCNVector3(0.25, -0.42, -1.45)
        title.position = SCNVector3(0, -0.65, -1.65)
        credit.position = SCNVector3(0, -0.77, -1.65)
    }

    func start(asset: OfflinePanoramaAsset, scene: SCNScene, head: SCNNode) {
        stop()
        isRunning = true
        scene.rootNode.addChildNode(root)
        recenter(head: head)
        title.setText("Загрузка 360°…"); title.fitWidth(0.95)
        credit.setText("\(asset.author) · \(asset.license)"); credit.fitWidth(1.1)
        let geometry = makeSphere(focusU: asset.focusU)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(white: 0.025, alpha: 1)
        material.isDoubleSided = true
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .clamp
        material.diffuse.mipFilter = .linear
        geometry.firstMaterial = material
        sphere.geometry = geometry
        let token = generation
        let url = Bundle.main.url(forResource: asset.filename, withExtension: nil, subdirectory: "Panoramas")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image: UIImage? = autoreleasepool {
                guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }
            DispatchQueue.main.async {
                guard let self, self.isRunning, self.generation == token else { return }
                if let image {
                    material.diffuse.contents = image
                    self.title.setText(asset.title)
                } else {
                    self.title.setText("Панорама не загрузилась · нажми ‹ Места")
                }
                self.title.fitWidth(1.15)
            }
        }
    }

    func stop() {
        generation = UUID()
        isRunning = false
        cancelInput()
        root.removeFromParentNode()
        sphere.geometry = nil
    }

    func recenter(head: SCNNode) {
        let t = head.simdWorldTransform
        yaw = PanoramaProjection.yaw(forward: SIMD3(-t.columns.2.x, -t.columns.2.y, -t.columns.2.z), fallback: yaw)
        root.eulerAngles = SCNVector3(0, yaw, 0)
        followPosition(head: head)
    }

    func followPosition(head: SCNNode) {
        guard isRunning else { return }
        // Follow position only. Copying rotation would lock the photo to the face.
        root.simdWorldPosition = head.simdWorldPosition
    }

    func cancelInput() {
        gate.cancel(); ring.isHidden = true
        home.setHighlight(false); center.setHighlight(false)
    }

    func update(ray: WorldRay?, pinch: Bool, allowBegin: Bool, dwell: Bool) {
        guard isRunning else { return }
        guard let ray else { cancelInput(); return }
        let target: Int? = home.hitTest(ray: ray) ? 0 : (center.hitTest(ray: ray) ? 1 : nil)
        home.setHighlight(target == 0); center.setHighlight(target == 1)
        let action = gate.update(target: target, down: pinch, allowBegin: allowBegin,
                                 dwell: dwell, at: CACurrentMediaTime())
        ring.show(on: target.map { $0 == 0 ? home.node : center.node }, progress: gate.dwellProgress)
        guard let action else { return }
        onInteraction?()
        if action == 0 { onExit?() } else { onRecenter?() }
    }

    private func makeSphere(focusU: Double) -> SCNGeometry {
        let columns = 96, rows = 48
        var vertices: [SCNVector3] = []
        var uv: [CGPoint] = []
        var indices: [Int32] = []
        for y in 0...rows {
            for x in 0...columns {
                let u = Double(x) / Double(columns), v = Double(y) / Double(rows)
                let p = PanoramaProjection.direction(u: u, v: v, focusU: focusU) * 40
                vertices.append(SCNVector3(p.x, p.y, p.z))
                uv.append(CGPoint(x: u, y: v))
            }
        }
        for y in 0..<rows {
            for x in 0..<columns {
                let a = Int32(y * (columns + 1) + x), b = a + 1
                let c = a + Int32(columns + 1), d = c + 1
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                     SCNGeometrySource(textureCoordinates: uv)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }
}
