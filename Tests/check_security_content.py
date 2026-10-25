"""Execute production trading rules, articulated physics and model construction."""
from pathlib import Path
import tempfile
from swift_test_support import run_swift_sources
root = Path(__file__).resolve().parent.parent
shim = (root/'Tests/TimeMotionSceneShim.swift').read_text(encoding='utf-8')
a=shim.index('class TMSoundBank {');b=shim.index('class DwellProgressRing',a)
shim=shim[:a]+shim[b:]
shim=shim.replace('case constant,lambert','case constant,lambert,physicallyBased')
shim=shim.replace('let diffuse=SCNProperty()','let diffuse=SCNProperty(),metalness=SCNProperty(),roughness=SCNProperty()')
shim=shim.replace('var geometry:SCNGeometry?,light:', 'var name:String?\n    var geometry:SCNGeometry?,light:')
shim=shim.replace('static let white=Self', 'static let systemBlue=Self(red:0,green:0,blue:1,alpha:1),systemYellow=Self(red:1,green:1,blue:0,alpha:1),systemTeal=Self(red:0,green:0.5,blue:0.5,alpha:1)\n    static let white=Self')
shim+='\nclass SCNCapsule:SCNGeometry {var radialSegmentCount=24,heightSegmentCount=1;init(capRadius:CGFloat,height:CGFloat){}}\n'
models=(root/'HandARBrowser/SecurityVRModels.swift').read_text(encoding='utf-8')
models='import Foundation\n'+'\n'.join(line for line in models.splitlines() if not line.startswith('import '))
# Compile the actual guest/game orchestration too; only image drawing is substituted.
game=(root/'HandARBrowser/SecurityVRGame.swift').read_text(encoding='utf-8')
a=game.index('private func renderLabelImage');b=game.index('private final class SecurityButton',a)
game=game[:a]+game[b:]
a=game.index('        // Надпись рисуем');b=game.index('        node.constraints',a)
game=game[:a]+game[b:]
game='import Foundation\n'+'\n'.join(line for line in game.splitlines() if not line.startswith('import '))
game=game.replace('private(set) ','').replace('private ','')
shim=shim.replace('let diffuse=SCNProperty(),metalness=SCNProperty(),roughness=SCNProperty()',
                  'let diffuse=SCNProperty(),metalness=SCNProperty(),roughness=SCNProperty(),emission=SCNProperty()')
shim=shim.replace('var name:String?', 'var opacity:CGFloat=1\n    var presentation:SCNNode { self }\n    var name:String?')
shim=shim.replace('init(_ vector: SIMD3<Float>)', 'init<T:BinaryFloatingPoint>(_ x:T,_ y:T,_ z:T) {self.init(Float(x),Float(y),Float(z))}\n    init(_ vector: SIMD3<Float>)')
shim=shim.replace('var simdWorldPosition:SIMD3<Float> { (parent?.simdWorldPosition ?? .zero)+position.vector }',
'var simdWorldPosition:SIMD3<Float> { world(.zero) }')
shim=shim.replace('func convertPosition(_ p:SCNVector3,to:SCNNode?)->SCNVector3 {SCNVector3(simdWorldPosition+simdOrientation.act(p.vector))}',
"""func world(_ p:SIMD3<Float>)->SIMD3<Float> { let point=simdPosition+simdOrientation.act(p);return parent?.world(point) ?? point }
    func local(_ p:SIMD3<Float>)->SIMD3<Float> {let point=(parent?.local(p) ?? p)-simdPosition;var inverse=simdOrientation;inverse.vector.x *= -1;inverse.vector.y *= -1;inverse.vector.z *= -1;return inverse.act(point)}
    func convertPosition(_ p:SCNVector3,to node:SCNNode?)->SCNVector3 {let p=world(p.vector);return SCNVector3(node?.local(p) ?? p)}
    func convertPosition(_ p:SCNVector3,from node:SCNNode?)->SCNVector3 {SCNVector3(local(node?.world(p.vector) ?? p.vector))}""")
shim+='\nlet SCNVector3Zero=SCNVector3(0,0,0)\ntypealias simd_float3=SIMD3<Float>\nfunc simd_distance(_ a:SIMD3<Float>,_ b:SIMD3<Float>)->Float {simd_length(a-b)}\nvar testClock=0.0\nfunc CACurrentMediaTime()->Double {testClock}\nclass TextSprite:SCNNode {\n var current="",maximumWidth:Float?\n func setText(_ value:String,color:UIColor = .white){current=value}\n func fitWidth(_ width:Float){}\n}\nclass UIImpactFeedbackGenerator {\n enum Style {case light,medium,heavy}\n init(style:Style){}\n func impactOccurred(){}\n}\nextension UIColor {\n static let systemRed=Self(red:1,green:0,blue:0,alpha:1),systemGreen=Self(red:0,green:1,blue:0,alpha:1)\n static let systemOrange=Self(red:1,green:0.5,blue:0,alpha:1),systemPurple=Self(red:0.5,green:0,blue:1,alpha:1)\n static let darkGray=Self(white:0.15,alpha:1),orange=Self.systemOrange,black=Self(white:0,alpha:1)\n}\n'
with tempfile.TemporaryDirectory(prefix='handar-security-content-') as directory:
    a=Path(directory)/'Shim.swift';a.write_text(shim,encoding='utf-8')
    b=Path(directory)/'Models.swift';b.write_text(models,encoding='utf-8')
    c=Path(directory)/'Game.swift';c.write_text(game,encoding='utf-8')
    run_swift_sources([root/'HandARBrowser/HandGesture.swift',root/'HandARBrowser/GraffitiState.swift',
        root/'HandARBrowser/GraffitiPhysics.swift',root/'HandARBrowser/TimeMotionLogic.swift',
        root/'HandARBrowser/SecurityVRContent.swift',a,b,c,root/'Tests/SecurityContentTests.swift'])
