//
//  MainViewController.swift
//  HandAR Vision — V80
//
//  Стереоконвейер
//  Передний план: реальные пиксели рук из камеры по узкой маске свежих суставов Vision.
//  --------------
//    ARKit (поза головы)
//        └─► одна SCNScene, две камеры на реальном IPD
//              └─► SCNRenderer × 2 → офскрин-текстура (левая/правая половина)
//                    └─► Metal: YCbCr-passthrough пер-глаз, barrel-предыскажение,
//                        хроматика, маска линзы
//                          └─► экран
//
//  Управление
//  ----------
//    • Луч выходит из кончика указательного пальца. Где он встречает панель,
//      там горит точка с кольцом — видно, куда наведён.
//    • Нажатие: удержание курсора 1 с или щипок с подтверждённым отпусканием.
//    • Перетаскивание панели: устойчивый кулак, луч направлен на панель.
//    • Масштаб: две руки, указательный + большой на каждой; двигаем указательные
//      дальше друг от друга — окно увеличивается, ближе — уменьшается.
//    • Панель ссылок над браузером: Google, YouTube, TikTok, Назад.
//

import UIKit
import AVFoundation
import ARKit
import SceneKit
import Vision
import WebKit
import GameController
import Metal
import MetalKit
import simd

struct HandSample {
    let hand: TrackedHand
    let timestamp: Double
    let generation: UInt64
    /// Identity of this tracked hand, independent of pinch cancellation.
    var trackingGeneration: UInt64 = 0
    let indexTip: CGPoint
    let middleTip: CGPoint
    let thumbTip: CGPoint
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    /// Only current, confident landmarks may cut holes in the virtual surface.
    let maskJoints: [VNHumanHandPoseObservation.JointName: CGPoint]
    let imageSize: SIMD2<Double>
    /// Confirmed thumb + index contact, held until confirmed opening.
    let clickPinch: Bool
    let clickBegan: Bool
    let clickOpenConfirmed: Bool
    /// Compatibility field: panel grabbing is a fist, not another pinch.
    let grabPinch: Bool
    let isFist: Bool

    var openPalmCenter: CGPoint? {
        guard !isFist, !clickPinch, let wrist=maskJoints[.wrist],
              let base=maskJoints[.middleMCP] else { return nil }
        let fingers: [(VNHumanHandPoseObservation.JointName,VNHumanHandPoseObservation.JointName)] = [
            (.indexTip,.indexMCP),(.middleTip,.middleMCP),(.ringTip,.ringMCP),(.littleTip,.littleMCP)]
        for (tip,mcp) in fingers {
            guard let tip=maskJoints[tip],let mcp=maskJoints[mcp],
                  distance(wrist,tip) > distance(wrist,mcp)*1.35 else { return nil }
        }
        return CGPoint(x:(wrist.x+base.x)*0.5,y:(wrist.y+base.y)*0.5)
    }

    var routing: HandRoutingState {
        HandRoutingState(hand:hand,generation:generation,down:clickPinch,openConfirmed:clickOpenConfirmed)
    }
    func routed(down: Bool, began: Bool) -> HandSample {
        HandSample(hand:hand,timestamp:timestamp,generation:generation,trackingGeneration:trackingGeneration,indexTip:indexTip,
            middleTip:middleTip,thumbTip:thumbTip,joints:joints,maskJoints:maskJoints,imageSize:imageSize,clickPinch:down,
            clickBegan:began,clickOpenConfirmed:clickOpenConfirmed,grabPinch:grabPinch,isFist:isFist)
    }
}

/// Луч в мировых координатах.
struct WorldRay {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>

    func point(at distance: Float) -> SIMD3<Float> {
        origin + direction * distance
    }
}

// MARK: - Профиль шлема --------------------------------------------------------

/// Физика шлема и линз. Все линейные размеры — в миллиметрах.
struct VRProfile: Codable, Equatable {
    /// Ширина активной области экрана в ландшафте (длинная сторона).
    var screenWidthMM: Float
    /// Высота активной области экрана в ландшафте (короткая сторона).
    var screenHeightMM: Float

    /// Legacy IPD retained in saved profiles; the shared camera has no baseline.
    var ipdMM: Float = 63
    /// Расстояние между центрами линз шлема.
    var lensSeparationMM: Float = 63
    /// Смещение центров линз по вертикали относительно центра экрана.
    var lensVerticalOffsetMM: Float = 0
    // Optional fields preserve synthesized decoding of profiles saved before V83.
    var screenHorizontalOffsetMM: Float? = nil
    var rightEyeVerticalOffsetMM: Float? = nil
    /// Расстояние от глаза до экрана сквозь линзу.
    var eyeToScreenMM: Float = 42

    /// Коэффициенты радиального предыскажения.
    var k1: Float = 0.0
    var k2: Float = 0.0
    /// Без искусственной хроматики: картинка заполняет весь экран.
    var chroma: Float = 0.0
    /// Legacy setting retained for saved profiles. Eyes now fill the display.
    var lensClipRadius: Float = 0.0

    /// Запас поля зрения под предыскажение. Больше — картинка плотнее
    /// заполняет круглую линзу, меньше чёрных полей по краю.
    var fovScale: Float = 1.0
    /// Суперсэмплинг офскрин-буфера.
    var supersample: Float = 1.2

    /// Сквозное видео с камеры.
    var passthrough: Bool = true

    static let storageKey = "handar.vr.profile.v2"

    static func makeDefault() -> VRProfile {
        let native = UIScreen.main.nativeBounds
        let longPx = Float(max(native.width, native.height))
        let shortPx = Float(min(native.width, native.height))
        let mmPerPixel = 25.4 / estimatedPPI()
        return VRProfile(screenWidthMM: longPx * mmPerPixel,
                         screenHeightMM: shortPx * mmPerPixel)
    }

    private static func estimatedPPI() -> Float {
        var info = utsname()
        uname(&info)
        let model = withUnsafePointer(to: &info.machine) { pointer -> String in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        // SE-корпуса — 326 ppi, остальные современные iPhone — около 460.
        if model.hasPrefix("iPhone8,4")
            || model.hasPrefix("iPhone12,8")
            || model.hasPrefix("iPhone14,6") {
            return 326
        }
        return UIScreen.main.scale >= 3 ? 460 : 326
    }

    static func load() -> VRProfile {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            var decoded = try? JSONDecoder().decode(VRProfile.self, from: data)
        else {
            return makeDefault()
        }
        // Screen dimensions belong to this phone, not a previously saved device.
        let actual = makeDefault()
        decoded.screenWidthMM = actual.screenWidthMM
        decoded.screenHeightMM = actual.screenHeightMM
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: VRProfile.storageKey)
    }
}

/// Границы пирамиды видимости на единичном расстоянии (тангенсы углов).
struct EyeFrustum {
    var left: Float
    var right: Float
    var bottom: Float
    var top: Float
}

enum VRLensMath {
    /// Both outputs sample one central-camera image. Physical lens placement
    /// changes output UV centers, never the shared scene projection.
    static func frustum(eye: Int, profile: VRProfile) -> EyeFrustum {
        _ = eye
        let depth=max(profile.eyeToScreenMM,1), scale=max(profile.fovScale,1)
        let x=profile.screenWidthMM*0.25/depth*scale
        let y=profile.screenHeightMM*0.5/depth*scale
        return EyeFrustum(left:-x,right:x,bottom:-y,top:y)
    }

    static func lensCenterUV(eye: Int, profile: VRProfile) -> SIMD2<Float> {
        let center=MonoViewGeometry.lensCenter(eye:eye,
            screenWidth:Double(profile.screenWidthMM),screenHeight:Double(profile.screenHeightMM),
            separation:Double(profile.lensSeparationMM),horizontal:Double(profile.screenHorizontalOffsetMM ?? 0),
            vertical:Double(profile.lensVerticalOffsetMM),rightVertical:Double(profile.rightEyeVerticalOffsetMM ?? 0))
        return SIMD2(Float(center.x),Float(center.y))
    }

    static func renderScale(profile: VRProfile, aspect: Float) -> Float {
        let centers=(0..<2).map { eye -> SIMD2<Double> in
            let p=lensCenterUV(eye:eye,profile:profile);return SIMD2(Double(p.x),Double(p.y))
        }
        return Float(MonoViewGeometry.renderScale(centers:centers,aspect:Double(aspect),
            k1:Double(profile.k1),k2:Double(profile.k2),chroma:Double(profile.chroma)))
    }

    static func projection(_ frustum: EyeFrustum, near: Float, far: Float) -> SCNMatrix4 {
        let left = frustum.left * near
        let right = frustum.right * near
        let bottom = frustum.bottom * near
        let top = frustum.top * near

        var matrix = SCNMatrix4Identity
        matrix.m11 = 2 * near / (right - left)
        matrix.m12 = 0; matrix.m13 = 0; matrix.m14 = 0
        matrix.m21 = 0
        matrix.m22 = 2 * near / (top - bottom)
        matrix.m23 = 0; matrix.m24 = 0
        matrix.m31 = (right + left) / (right - left)
        matrix.m32 = (top + bottom) / (top - bottom)
        matrix.m33 = -(far + near) / (far - near)
        matrix.m34 = -1
        matrix.m41 = 0; matrix.m42 = 0
        matrix.m43 = -2 * far * near / (far - near)
        matrix.m44 = 0
        return matrix
    }
}

// MARK: - Metal-композитор -----------------------------------------------------

private struct VRUniforms {
    var lensCenterL = SIMD2<Float>(0.5, 0.5)
    var lensCenterR = SIMD2<Float>(0.5, 0.5)
    var camScaleL = SIMD2<Float>(1, 1)
    var camOffsetL = SIMD2<Float>(0, 0)
    var camScaleR = SIMD2<Float>(1, 1)
    var camOffsetR = SIMD2<Float>(0, 0)
    var aspect: Float = 1
    var k1: Float = 0
    var k2: Float = 0
    var chroma: Float = 0
    var rClip: Float = 1
    var passthrough: Float = 1
    var handMaskEnabled: Float = 0
    var overscan: Float = 1
    var handRemovalEnabled: Float = 0
}

/// Финальный проход. Берёт офскрин-текстуру глаз (левый глаз слева, правый справа),
/// подкладывает под неё сквозное видео с камеры и продавливает всё через оптику линз.
final class VRCompositor {
    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState?

    init?(device: MTLDevice) {
        self.device = device
        guard makePipeline() else { return nil }
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 pos [[position]];
        float2 uv;
    };

    struct VRUniforms {
        float2 lensCenterL;
        float2 lensCenterR;
        float2 camScaleL;
        float2 camOffsetL;
        float2 camScaleR;
        float2 camOffsetR;
        float aspect;
        float k1;
        float k2;
        float chroma;
        float rClip;
        float passthrough;
        float handMaskEnabled;
        float overscan;
        float handRemovalEnabled;
    };

    vertex VOut vr_vertex(uint vid [[vertex_id]]) {
        float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        VOut out;
        out.pos = float4(corners[vid], 0.0, 1.0);
        out.uv = float2((corners[vid].x + 1.0) * 0.5, (1.0 - corners[vid].y) * 0.5);
        return out;
    }

    inline float3 ycbcr_to_rgb(float y, float2 cbcr) {
        float cb = cbcr.x - 0.5;
        float cr = cbcr.y - 0.5;
        return float3(y + 1.402 * cr,
                      y - 0.344136 * cb - 0.714136 * cr,
                      y + 1.772 * cb);
    }

    // Approximate concealed wall color using nearby unmasked camera pixels.
    // Bounded cost, no frame history that would trail behind a moving camera.
    // Only used in Graffiti home mode, before compositing paint and gloves.
    inline float3 concealedHandBackground(float2 uv, texture2d<float> camY,
                                         texture2d<float> camCbCr, texture2d<float> mask) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);
        const float2 directions[8] = {float2(1,0),float2(-1,0),float2(0,1),float2(0,-1),
            float2(0.707,0.707),float2(-0.707,0.707),float2(0.707,-0.707),float2(-0.707,-0.707)};
        float aspect = float(camY.get_height()) / float(camY.get_width());
        float3 sum = float3(0.0);
        float weights = 0.0;
        for (int d = 0; d < 8; d++) {
            for (int step = 1; step <= 8; step++) {
                float radius = 0.018 * float(step * step);
                float2 candidate = uv + directions[d] * float2(aspect,1.0) * radius;
                if (any(candidate < 0.0) || any(candidate > 1.0)) { break; }
                if (mask.sample(smp,candidate).r < 0.02) {
                    float weight = 1.0 / radius;
                    float y = camY.sample(smp,candidate).r;
                    float2 cc = camCbCr.sample(smp,candidate).rg;
                    sum += clamp(ycbcr_to_rgb(y,cc),0.0,1.0) * weight;
                    weights += weight;
                    break;
                }
            }
        }
        // No reliable surrounding pixels: use a neutral patch, not the hand.
        return weights > 0.0 ? sum / weights : float3(0.18);
    }

    fragment float4 vr_fragment(VOut in [[stage_in]],
                                texture2d<float> eyes [[texture(0)]],
                                texture2d<float> camY [[texture(1)]],
                                texture2d<float> camCbCr [[texture(2)]],
                                texture2d<float> handMask [[texture(3)]],
                                constant VRUniforms &u [[buffer(0)]]) {
        constexpr sampler smp(filter::linear, address::clamp_to_edge);

        float eye = in.uv.x < 0.5 ? 0.0 : 1.0;
        float2 eyeUV = float2((in.uv.x - eye * 0.5) * 2.0, in.uv.y);
        float2 center = (eye < 0.5) ? u.lensCenterL : u.lensCenterR;

        // Изотропное пространство линзы.
        float2 p = (eyeUV - center) * float2(u.aspect, 1.0);
        float r2 = dot(p, p);
        float r = sqrt(r2);

        // Предыскажение: берём источник дальше от центра, чтобы линза,
        // растягивающая картинку наружу, вернула прямые линии прямыми.
        float f = 1.0 + u.k1 * r2 + u.k2 * r2 * r2;
        float2 inv = float2(1.0 / u.aspect, 1.0) / u.overscan;
        float2 sourceCenter = float2(0.5, 0.5);
        float2 sampleG = sourceCenter + p * f * inv;
        float2 sampleR = sourceCenter + p * (f * (1.0 + u.chroma)) * inv;
        float2 sampleB = sourceCenter + p * (f * (1.0 - u.chroma)) * inv;


        // Never let bilinear filtering read pixels from the other eye.
        float2 inset = float2(1.0 / float(eyes.get_width()), 0.5 / float(eyes.get_height()));
        sampleG = clamp(sampleG, inset, 1.0 - inset);
        sampleR = clamp(sampleR, inset, 1.0 - inset);
        sampleB = clamp(sampleB, inset, 1.0 - inset);
        // BOTH eyes read exactly the same left-hand image from this frame.
        float2 off = float2(0.0);
        float4 cg = eyes.sample(smp, float2(sampleG.x * 0.5, sampleG.y) + off);
        float cr = eyes.sample(smp, float2(sampleR.x * 0.5, sampleR.y) + off).r;
        float cb = eyes.sample(smp, float2(sampleB.x * 0.5, sampleB.y) + off).b;

        float3 overlay = float3(cr, cg.g, cb);
        float alpha = cg.a;

        float3 background = float3(0.0);
        float2 camUV = float2(-1.0);
        bool validCamUV = false;
        // Hand-only camera sampling also works inside an opaque virtual room.
        if (u.passthrough > 0.5 || u.handMaskEnabled > 0.5) {
            float2 camScale = (eye < 0.5) ? u.camScaleL : u.camScaleR;
            float2 camOffset = (eye < 0.5) ? u.camOffsetL : u.camOffsetR;
            camUV = sampleG * camScale + camOffset;
            // Rounding / intrinsics updates at the last pixel must not create a
            // black border. The calibrated coverage already fits the full frame.
            camUV = clamp(camUV, float2(0.0), float2(1.0));
            validCamUV = true;
            if (u.passthrough > 0.5 && validCamUV) {
                float yy = camY.sample(smp, camUV).r;
                float2 cc = camCbCr.sample(smp, camUV).rg;
                background = clamp(ycbcr_to_rgb(yy, cc), 0.0, 1.0);
            }
        }

        if (u.handRemovalEnabled > 0.5 && u.passthrough > 0.5 && validCamUV && alpha < 0.999) {
            float removalAlpha = handMask.sample(smp, camUV).r;
            if (removalAlpha > 0.01) {
                float3 fill = concealedHandBackground(camUV, camY, camCbCr, handMask);
                background = mix(background, fill, removalAlpha);
            }
        }
        float3 color = mix(background, overlay, clamp(alpha, 0.0, 1.0));

        // Реальный передний план руки: маска задаётся Vision, цвет берётся
        // непосредственно из текущего кадра камеры, поэтому рука находится
        // поверх виртуальной сцены без нарисованного скелета.
        if (u.handMaskEnabled > 0.5 && validCamUV) {
            float handAlpha = handMask.sample(smp, camUV).r;
            if (handAlpha > 0.01) {
                float yyHand = camY.sample(smp, camUV).r;
                float2 ccHand = camCbCr.sample(smp, camUV).rg;
                float3 handColor = clamp(ycbcr_to_rgb(yyHand, ccHand), 0.0, 1.0);
                color = mix(color, handColor, handAlpha);
            }
        }

        return float4(color, 1.0);
    }
    """

    private func makePipeline() -> Bool {
        do {
            // Компиляция в рантайме: не требует .metal-файла в проекте.
            let library = try device.makeLibrary(source: VRCompositor.source, options: nil)
            guard
                let vertexFunction = library.makeFunction(name: "vr_vertex"),
                let fragmentFunction = library.makeFunction(name: "vr_fragment")
            else {
                return false
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            return true
        } catch {
            NSLog("VRCompositor: шейдер не собрался — \(error)")
            return false
        }
    }

    fileprivate func encode(
        into encoder: MTLRenderCommandEncoder,
        eyeTexture: MTLTexture,
        cameraY: MTLTexture?,
        cameraCbCr: MTLTexture?,
        handMask: MTLTexture,
        uniforms: VRUniforms
    ) {
        guard let pipeline else { return }
        var local = uniforms
        if cameraY == nil || cameraCbCr == nil {
            local.passthrough = 0
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(eyeTexture, index: 0)
        encoder.setFragmentTexture(cameraY ?? eyeTexture, index: 1)
        encoder.setFragmentTexture(cameraCbCr ?? eyeTexture, index: 2)
        encoder.setFragmentTexture(handMask, index: 3)
        encoder.setFragmentBytes(&local, length: MemoryLayout<VRUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

// MARK: - Панель ссылок --------------------------------------------------------

/// Кнопка на планке над браузером.
struct ToolbarItem {
    enum Action {
        case open(URL)
        case back
        case home
        case center
        case reload
        case size
    }

    let title: String
    let action: Action
    /// Границы по локальной оси X панели, в метрах от её центра.
    var minX: Float = 0
    var maxX: Float = 0
}

// MARK: - Главный контроллер ---------------------------------------------------

// Pure policy shared by browser capture, Vision and offscreen rendering.
struct VRPerformanceBudget {
    let thermalLevel: Int

    var handFrameInterval: Double {
        switch thermalLevel {
        case 2: return 1.0 / 20.0
        case 3...: return 1.0 / 15.0
        default: return 1.0 / 30.0
        }
    }

    var maximumRenderScale: Double {
        switch thermalLevel {
        case 1: return 1.1
        case 2: return 1.0
        case 3...: return 0.85
        default: return 2.0
        }
    }

    func snapshotInterval(home: Bool, cinema: Bool, interacting: Bool) -> Double {
        let fps: Double = cinema ? 24 : (home && !interacting ? 6 : 12)
        let thermalCap: Double = thermalLevel >= 2 ? 12 : 24
        return 1.0 / min(fps, thermalCap)
    }
}

// Unit-square to quadrilateral mapping. Independent of UIKit and SceneKit.
struct CinemaScreenHomography {
    let a: Double, b: Double, c: Double
    let d: Double, e: Double, f: Double
    let g: Double, h: Double

    init?(corners: [SIMD2<Double>]) {
        guard corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let p = corners
        let dx1 = p[1].x - p[2].x, dx2 = p[3].x - p[2].x
        let dy1 = p[1].y - p[2].y, dy2 = p[3].y - p[2].y
        let dx3 = p[0].x - p[1].x + p[2].x - p[3].x
        let dy3 = p[0].y - p[1].y + p[2].y - p[3].y
        let determinant = dx1 * dy2 - dx2 * dy1
        guard abs(determinant) > 0.000001 else { return nil }
        g = (dx3 * dy2 - dx2 * dy3) / determinant
        h = (dx1 * dy3 - dx3 * dy1) / determinant
        a = p[1].x - p[0].x + g * p[1].x
        b = p[3].x - p[0].x + h * p[3].x
        c = p[0].x
        d = p[1].y - p[0].y + g * p[1].y
        e = p[3].y - p[0].y + h * p[3].y
        f = p[0].y
        guard [a,b,c,d,e,f,g,h].allSatisfy({ $0.isFinite }),
              [1.0, 1+g, 1+g+h, 1+h].allSatisfy({ $0 > 0.000001 }) else { return nil }
    }

    func map(_ uv: SIMD2<Double>) -> SIMD2<Double>? {
        let w = g * uv.x + h * uv.y + 1
        guard abs(w) > 0.000001 else { return nil }
        let result = SIMD2((a * uv.x + b * uv.y + c) / w,
                           (d * uv.x + e * uv.y + f) / w)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

    func unmap(_ point: SIMD2<Double>) -> SIMD2<Double>? {
        let aa = a - point.x * g, bb = b - point.x * h
        let dd = d - point.y * g, ee = e - point.y * h
        let xx = point.x - c, yy = point.y - f
        let determinant = aa * ee - bb * dd
        guard abs(determinant) > 0.000001 else { return nil }
        let result = SIMD2((xx * ee - bb * yy) / determinant,
                           (aa * yy - xx * dd) / determinant)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// A busy main thread consumes only the newest sample, never a backlog of ARFrames.
private final class LatestMainDelivery<Value> {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private let consume: (Value) -> Void

    init(consume: @escaping (Value) -> Void) { self.consume = consume }

    func submit(_ value: Value) {
        lock.lock()
        latest = value
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let value = self.latest
            self.latest = nil
            self.scheduled = false
            self.lock.unlock()
            if let value { self.consume(value) }
        }
    }
}

final class MainViewController: UIViewController, MTKViewDelegate {
    private let tracking = ARStereoTrackingManager()
    private let hands = HandTracker()
    private let input = WebInputBridge()
    private let directLeftInput = WebInputBridge()
    private let controller = VRBoxControllerService()

    // Одна логическая поверхность браузера. Стерео рождается из двух камер,
    // а не из двух копий страницы.
    private var confirmationPlayer: AVAudioPlayer?
    private var lastConfirmationTime: CFTimeInterval = -.infinity
    private var spatialHomeVisible = true
    private let browserFrameNode = SCNNode()

    private let browser: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        // Видео не должно уходить из WKWebView в отдельный системный
        // fullscreen-контроллер: оно остаётся частью страницы и попадает
        // в тот же стерео-VR-композитор.
        config.preferences.isElementFullscreenEnabled = false

        let controller = WKUserContentController()
        if let path = Bundle.main.path(forResource: "WebInput", ofType: "js"),
           let js = try? String(contentsOfFile: path, encoding: .utf8) {
            controller.addUserScript(
                WKUserScript(
                    source: js,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }
        // Кино-пробник: забирает прямую ссылку на поток у <video> страницы,
        // чтобы кинотеатр играл её нативным AVPlayer (снимок WKWebView
        // аппаратное видео не захватывает — кадр был бы чёрным).
        controller.addUserScript(
            WKUserScript(
                source: MainViewController.cinemaProbeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.alwaysBounceVertical = true
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        return webView
    }()
    private var browserTimer: Timer?
    private var browserCaptureEnabled = false
    private var lastBrowserInteractionTime: CFTimeInterval = 0
    private var snapshotInProgress = false

    // Технологический обход чёрного YouTube-video: аппаратный HTML5 video
    // не попадает в WKWebView.takeSnapshot, поэтому в кинорежиме используем
    // один настоящий WKWebView с копированием его слоёв в обе VR-линзы.
    private let directVideoStage = UIView(frame: .zero)
    private let liveWebReplicator = MonoscopicWebReplicatorView(frame: .zero)
    private let cinemaEyeContainers = [UIView(), UIView()]
    private let cinemaWebPointers = [UIView(), UIView()]
    private var cinemaScreenMappings: [CinemaScreenHomography?] = [nil, nil]
    private var cinemaWebScreenActive: Bool { cinemaActive && directVideoActive }
    private var liveWebTransform: simd_float4x4? {
        cinemaWebScreenActive ? cinemaHall.screenWorldTransform : browserWorldTransform
    }
    private var liveWebSize: SIMD2<Float> {
        cinemaWebScreenActive ? SIMD2(CinemaHall.screenWidth, CinemaHall.screenHeight) : SIMD2(browserWorldWidth, browserWorldHeight)
    }
    private var directVideoLeft: WKWebView!
    private var directVideoActive = false
    private var directVideoURL: URL?
    private var cinemaWebLoadStartedAt: Double = 0
    private var cinemaWebRecoveryRequired = false
    private var directVideoGeneration = UUID()
    private var directVideoSyncTimer: Timer?
    private var directVideoSyncInFlight = false
    private var mediaAudioSessionActive = false

    // Metal
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var vrView: MTKView!
    private var compositor: VRCompositor?
    private var eyeTexture: MTLTexture?
    private var eyeDepthTexture: MTLTexture?
    private var eyeTextureSize: CGSize = .zero
    private var textureCache: CVMetalTextureCache?
    private var retainedCameraTextures: [CVMetalTexture] = []

    // CPU-маска кисти. Шейдер использует её только как альфа-маттинг для
    // настоящего изображения камеры, поэтому руки выглядят натурально.
    private let handMaskWidth = 512
    private let handMaskHeight = 384
    private var handMaskTexture: MTLTexture?
    private let handMaskLock = NSLock()
    private var pendingHandMaskBytes = [UInt8]()
    private var pendingHandMaskActive = false
    private var handMaskNeedsUpload = false
    private var handMaskTimestamp: Double = -.infinity

    // Сцена: одна на оба глаза
    private let worldScene = SCNScene()
    private var leftRenderer: SCNRenderer!
    private let headNode = SCNNode()
    private let leftCameraNode = SCNNode()
    private let browserPlaneNode = SCNNode()
    private let browserMaterial = SCNMaterial()

    // Указатель: луч из пальца плюс точка с кольцом в месте попадания.
    private let rayNode = SCNNode()
    private let pointerNode = SCNNode()
    private let pointerDotNode = SCNNode()
    private let pointerRingNode = SCNNode()

    // Скелеты рук находятся в той же мировой сцене, но имеют высокий
    // renderingOrder и отключённый depth test — поэтому они всегда поверх панели.
    private let leftHandSkeletonNode = SCNNode()
    private let rightHandSkeletonNode = SCNNode()
    private let controllerHandRoot = SCNNode()
    private let controllerHandTip = SCNNode()
    private var leftSkeletonJoints: [VNHumanHandPoseObservation.JointName: SCNNode] = [:]
    private var rightSkeletonJoints: [VNHumanHandPoseObservation.JointName: SCNNode] = [:]
    private var leftSkeletonBones: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, SCNNode)] = []
    private var rightSkeletonBones: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, SCNNode)] = []
    private var leftPalmNode: SCNNode?
    private var rightPalmNode: SCNNode?

    // Планка ссылок над браузером.
    private let toolbarNode = SCNNode()
    private var linkItems: [ToolbarItem] = []
    private var toolbarButtonNodes: [SCNNode] = []
    private var toolbarCenterY: Float = 0
    private let toolbarButtonHeight: Float = 0.14
    private var highlightedToolbarIndex: Int?
    private var toolbarImages: [(normal: UIImage, highlighted: UIImage)] = []

    private var menu: MainMenuView!
    private var lensCalibrationView: LensCalibrationView?
    private var returnToMenuAfterCalibration = false
    private var diagnosticsView: VRBoxDiagnosticsView?

    private var profile = VRProfile.load()
    private var inVR = false
    private var securityGameActive = false
    private var menuSwipe = OpenPalmSwipeGesture()
    private var cinemaNeedsAlignment = false
    private let securityGame = SecurityVRGame()
    private var timeMotionActive = false
    private var timeMotionCameraOverridden = false
    private var timeMotionAligned = false
    private var timeMotionHeadTimestamp: Double?
    private var timeMotionHeadMode: CameraMode?
    private var timeMotionLeft: HandSample?
    private var timeMotionRight: HandSample?
    private let timeMotion = TimeMotionVRGame()
    private var cinemaActive = false
    private let cinemaHall = CinemaHall()
    private let panorama = OfflinePanorama()
    private var panoramaActive: Bool { panorama.isRunning }
    private let graffiti = GraffitiStudio()
    private var graffitiMusicPicker: GraffitiMusicPicker?
    private let virtualHands = VirtualHands()
    private var graffitiActive: Bool { graffiti.isRunning }
    private var graffitiCameraOverridden = false
    private var graffitiTrackingReady: Bool {
        guard let frame = tracking.latestFrameCopy, frame.mode == .worldTracking, tracking.isCurrent(frame),
              CACurrentMediaTime() >= frame.timestamp, CACurrentMediaTime() - frame.timestamp <= 0.2,
              let camera = frame.camera.arCamera else { return false }
        if case .normal = camera.trackingState { return true }
        return false
    }
    private let cinemaControlMasks = [CAShapeLayer(), CAShapeLayer()]
    private let cinemaPlayback = CinemaPlayback()
    private var cameraPassthroughRequested: Bool {
        timeMotionActive ? false : (graffitiActive ? graffiti.mode == .home : (panoramaActive ? false : (cinemaActive ? cinemaHall.comfort.isPeeking : profile.passthrough)))
    }
    private var cinemaProbeTimer: Timer?
    private var cinemaProbeGeneration = UUID()
    private var snapshotGeneration = UUID()
    /// Ссылка, которую открыли в зале: её же пробник перезагружает,
    /// если страница не отдала поток с первого раза.
    private var cinemaSourceURL: URL?
    private var cinemaOriginalURL: URL?
    private var liveBrowserActive = false
    private var liveProcessRecoveries: Set<ObjectIdentifier> = []
    private var liveLoadError: String?
    private var directVideoStatusLabels: [UILabel] = []
    private var browserAnchor: ARAnchor?
    private var browserWorldTransform: simd_float4x4?
    private var didCreateInitialAnchor = false

    // Перетаскивание панели
    private var isDragging = false
    private var dragDistance: Float = 1.55
    private var dragOffset = SIMD3<Float>(repeating: 0)

    private var handClickMode = HandClickMode.load()
    private var pointerControlMode = PointerControlMode.load()
    private var usesHeadAim: Bool { pointerControlMode == .head }
    private var headAimSession = HeadAimSession()
    private var usesDwell: Bool { handClickMode == .dwell }
    private let toolbarDwellRing = DwellProgressRing()
    private var handOwnership = HandInputOwnership()
    private var handInputWatchdog: Timer?
    private var backgroundObserver: NSObjectProtocol?
    private var lastHandDeliveryTime: Double = -.infinity
    private var toolbarClickGate = ReleaseClickGate<Int>()
    private var controllerPointer = CGPoint(x: 0.5, y: 0.5)
    private var controllerButtonDown = false
    private var controllerConnected = false
    private var lastHandSeenTime: CFTimeInterval = 0
    private var controllerHandEuler = SIMD3<Float>(repeating: 0)
    private var controllerMotionAvailable = false
    private var controllerMotionRotation = SIMD3<Float>(repeating: 0)

    // Масштабирование двумя руками: обе руки делают указательный+большой палец,
    // затем расстояние между кончиками указательных меняет размер панели.
    private var isResizing = false
    private var resizeStartHandDistance: CGFloat = 0
    private var resizeStartWidth: Float = MainViewController.defaultPanelWidth

    // Панель браузера в мире. Размер большой намеренно: панель размером
    // с почтовый конверт на расстоянии вытянутой руки занимает жалкую часть
    // поля зрения и выглядит как маленький квадрат посреди черноты. Здесь
    // панель по умолчанию — это уже «большой монитор», а не окошко.
    private static let defaultPanelWidth: Float = 2.90
    private static let defaultPanelHeight: Float = 1.63
    private static let minimumPanelWidth: Float = 0.72
    private static let maximumPanelWidth: Float = 3.80
    private static let defaultPanelAspect: Float = defaultPanelHeight / defaultPanelWidth
    /// Видео на YouTube/TikTok разворачивается в «кинозал»: экран занимает
    /// большую часть поля зрения шлема, почти как в настоящем VR-кинотеатре.
    private static let cinemaPanelWidth: Float = 3.15
    private static let cinemaPanelHeight: Float = 1.77
    private var browserWorldWidth: Float = MainViewController.defaultPanelWidth
    private var browserWorldHeight: Float = MainViewController.defaultPanelHeight
    // Leave visible room around the floating window, including its toolbar.
    private let browserWorldDistance: Float = 2.15
    private var isCinemaMode = false
    private var browserPlaneGeometry: SCNPlane!
    private var browserFrameGeometry: SCNBox!
    private var browserHandleNode: SCNNode!
    /// На таком расстоянии от камеры рисуется начало луча — примерно там кисть.
    private let fingerRayOrigin: Float = 0.32

    override var prefersStatusBarHidden: Bool { true }
    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        [.landscapeLeft, .landscapeRight]
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }
    override var prefersHomeIndicatorAutoHidden: Bool { inVR }

    private static let homeURL = URL(string: "https://www.google.com/")!
    private static let youTubeURL = URL(string: "https://m.youtube.com/")!
    private static let tikTokURL = URL(string: "https://www.tiktok.com/")!
    private static let telegramURL = URL(string: "https://web.telegram.org/")!
    private static let discordURL = URL(string: "https://discord.com/app")!
    private static let spotifyURL = URL(string: "https://open.spotify.com/")!
    private static let mapsURL = URL(string: "https://maps.google.com/")!
    private static let gmailURL = URL(string: "https://mail.google.com/")!
    private static let redditURL = URL(string: "https://www.reddit.com/")!
    private static let wikipediaURL = URL(string: "https://www.wikipedia.org/")!

    /// Пробник плеера страницы: отдаёт прямую ссылку на поток, состояние
    /// воспроизведения и умеет растнуть видео на весь экран, спрятав обвязку
    /// сайта. Внедряется в каждый документ — нужен только кинотеатру.
    private static let cinemaProbeScript = """
    (function(){
      function largest(){
        var all = [].slice.call(document.querySelectorAll('video, audio'));
        all.sort(function(a,b){return (b.clientWidth*b.clientHeight)-(a.clientWidth*a.clientHeight);});
        return all[0] || null;
      }
      window.__handarVideoInfo = function(){
        try{
          var v = largest();
          if(!v) return JSON.stringify({ok:false});
          var src = v.currentSrc || v.src || '';
          var ready = v.readyState >= 1;
          // HLS-потоки, включая YouTube, отдают duration === Infinity —
          // это не ошибка, а живой/плейлистный поток. Достаточно прямой
          // ссылки и загруженных метаданных.
          var dur = isFinite(v.duration) ? (v.duration||0) : Infinity;
          var usable = !!src && src.indexOf('blob:') !== 0 && src.indexOf('data:') !== 0
                       && ready && (dur === Infinity || dur > 0.1);
          return JSON.stringify({ok:true, usable:usable, src:src, paused:v.paused,
                                 duration:dur, currentTime:(v.currentTime||0),
                                 volume:(typeof v.volume === 'number' ? v.volume : 1),
                                 muted:!!v.muted});
        }catch(e){ return JSON.stringify({ok:false}); }
      };
      window.__handarCinemaCommand = function(cmd, arg){
        try{
          var v = largest();
          if(!v) return 'null';
          if(cmd === 'play'){
            // Автозапуск без жеста на iOS разрешён только для беззвучного
            // видео. Звук потом берёт нативный плеер зала, страница молчит.
            var p = v.play();
            if(p && p.catch){
              p.catch(function(){
                try{ v.muted = true; var q = v.play(); if(q && q.catch){ q.catch(function(){}); } }catch(e){}
              });
            }
          }
          else if(cmd === 'pause'){ v.pause(); }
          else if(cmd === 'mute'){ v.muted = true; }
          else if(cmd === 'unmute'){ v.muted = false; }
          else if(cmd === 'volume'){
            v.volume = Math.max(0, Math.min(1, parseFloat(arg || '1')));
            v.muted = false;
          }
          else if(cmd === 'fill'){
            var st = document.getElementById('__handar-cinema-css');
            if(!st){
              st = document.createElement('style');
              st.id = '__handar-cinema-css';
              document.documentElement.appendChild(st);
            }
            st.textContent =
              'html,body{margin:0!important;padding:0!important;background:#000!important;overflow:hidden!important}' +
              '.html5-video-container,.html5-main-video,video{position:fixed!important;left:0!important;top:0!important;' +
              'width:100vw!important;height:100vh!important;max-width:100vw!important;max-height:100vh!important;' +
              'object-fit:cover!important;z-index:2147483640!important;background:#000!important}' +
              '.ytp-chrome-bottom,.ytp-chrome-top,.ytp-gradient-bottom,.ytp-gradient-top,.ytp-paid-content-overlay,' +
              '.ytp-ce-element,.ytp-large-play-button,.ytp-pause-overlay,.ytp-cards-teaser,#player-hero,' +
              '.mobile-topbar-header,#masthead-container{display:none!important}';
          }
          return JSON.stringify({paused:v.paused, currentTime:(v.currentTime||0)});
        }catch(e){ return 'null'; }
      };
    })();
    """

    private func isDirectMediaURL(_ url: URL) -> Bool {
        let extensions = ["mp4", "m3u8", "mov", "m4v"]
        return extensions.contains(url.pathExtension.lowercased())
    }

    /// Resolve supported YouTube links to an ordinary watch page. The live web
    /// player keeps the site's actual video layer visible instead of snapshotting it.
    private func youtubeWatchURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") ||
              host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
        else { return nil }
        var id: String?
        if host == "youtu.be" {
            id = url.lastPathComponent
        } else if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            id = value
        } else {
            let path = url.path.lowercased()
            if path.contains("/shorts/") || path.contains("/embed/") || path.contains("/live/") {
                id = url.lastPathComponent
            }
        }
        guard let id, id.count == 11,
              id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
        else { return nil }
        var components = URLComponents(string: "https://m.youtube.com/watch")!
        components.queryItems = [URLQueryItem(name: "v", value: id)]
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let time = query.first(where: { $0.name == "t" || $0.name == "start" })?.value {
            components.queryItems?.append(URLQueryItem(name: "t", value: time))
        }
        return components.url
    }

    private func isYouTubePage(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") ||
               host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    // MARK: Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        UIDevice.current.isBatteryMonitoringEnabled = true
        view.backgroundColor = .black
        configureMetal()
        configureScene()
        configureBrowser()
        if let url = Bundle.main.url(forResource: "UIConfirm", withExtension: "wav") {
            confirmationPlayer = try? AVAudioPlayer(contentsOf: url)
            confirmationPlayer?.volume = 0.35
            confirmationPlayer?.prepareToPlay()
        }
        buildInterface()
        wireServices()
        backgroundObserver=NotificationCenter.default.addObserver(forName:UIApplication.didEnterBackgroundNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self,self.inVR else { return };self.leaveVRToMenu()
        }
        handInputWatchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.inVR, !self.usesHeadAim,
                  (self.handOwnership.hand != nil || self.securityGame.inputHand != nil),
                  CACurrentMediaTime()-self.lastHandDeliveryTime > 0.2 else { return }
            self.cancelHandInteraction()
            self.handOwnership.reset()
            self.hands.reset()
            self.endDrag()
            self.endResize()
        }
        if let watchdog = handInputWatchdog { RunLoop.main.add(watchdog,forMode:.common) }
        controller.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestLandscapeMode()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutViews()
        layoutDirectVideoStage()
        applyEyeGeometry()
        tracking.setInterfaceOrientation(currentInterfaceOrientation())
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.tracking.setInterfaceOrientation(self.currentInterfaceOrientation())
            self.eyeTexture = nil
        }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        handInputWatchdog?.invalidate()
        cinemaProbeTimer?.invalidate()
        cinemaPlayback.release()
        tracking.pause()
        browserTimer?.invalidate()
        directVideoSyncTimer?.invalidate()
        removeDirectVideoMessageHandlers()
        if mediaAudioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        // WKUserContentController держит обработчик сильной ссылкой —
        // без явного снятия получился бы цикл ретейнов.
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "handarVideo")
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "handarApp")
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "handarSystem")
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "handarFeedback")
        controller.stop()
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }

    // MARK: Сборка

    private func configureMetal() {
        guard
            let metalDevice = MTLCreateSystemDefaultDevice(),
            let queue = metalDevice.makeCommandQueue()
        else {
            showAlert("Metal недоступен на этом устройстве.")
            return
        }

        device = metalDevice
        commandQueue = queue
        compositor = VRCompositor(device: metalDevice)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &textureCache)

        let handMaskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: handMaskWidth,
            height: handMaskHeight,
            mipmapped: false
        )
        handMaskDescriptor.usage = [.shaderRead]
        handMaskDescriptor.storageMode = .shared
        handMaskTexture = metalDevice.makeTexture(descriptor: handMaskDescriptor)

        vrView = MTKView(frame: view.bounds, device: metalDevice)
        vrView.colorPixelFormat = .bgra8Unorm
        vrView.depthStencilPixelFormat = .invalid
        vrView.framebufferOnly = true
        vrView.preferredFramesPerSecond = 60
        vrView.enableSetNeedsDisplay = false
        vrView.autoResizeDrawable = true
        vrView.isPaused = true
        vrView.isOpaque = true
        vrView.backgroundColor = .black
        vrView.delegate = self

        leftRenderer = SCNRenderer(device: metalDevice, options: nil)
        for renderer in [leftRenderer] {
            renderer?.scene = worldScene
            renderer?.autoenablesDefaultLighting = false
            renderer?.isJitteringEnabled = false
        }
    }

    private func configureScene() {
        // Фон сцены прозрачный: сквозное видео подкладывает композитор,
        // отдельно для каждого глаза и с учётом его фрустума.
        worldScene.background.contents = UIColor.clear

        let leftCamera = SCNCamera()
        leftCamera.zNear = 0.02
        leftCamera.zFar = 100
        leftCameraNode.camera = leftCamera

        headNode.addChildNode(leftCameraNode)
        worldScene.rootNode.addChildNode(headNode)
        applyEyeGeometry()

        buildBrowserPanel()
        buildToolbar()
        buildPointer()
        buildControllerHand()
        // 3D-скелет больше не показываем: поверх браузера выводим настоящие
        // пиксели руки из камеры через handMaskTexture.
    }

    private func buildBrowserPanel() {
        let geometry = SCNPlane(
            width: CGFloat(browserWorldWidth),
            height: CGFloat(browserWorldHeight)
        )
        geometry.widthSegmentCount = 1
        geometry.heightSegmentCount = 1
        geometry.cornerRadius = 0.045

        browserMaterial.lightingModel = .constant
        browserMaterial.isDoubleSided = true
        browserMaterial.diffuse.contents = UIColor.black
        browserMaterial.emission.contents = UIColor.black
        browserMaterial.specular.contents = UIColor.black
        browserMaterial.diffuse.wrapS = .clamp
        browserMaterial.diffuse.wrapT = .clamp
        browserMaterial.shininess = 0
        browserMaterial.blendMode = .alpha
        browserMaterial.writesToDepthBuffer = false
        geometry.firstMaterial = browserMaterial
        browserPlaneGeometry = geometry

        browserPlaneNode.geometry = geometry
        browserPlaneNode.isHidden = true
        worldScene.rootNode.addChildNode(browserPlaneNode)

        // Рамка: мозгу нужен край, чтобы зацепиться за глубину панели.
        let frameGeometry = SCNBox(
            width: CGFloat(browserWorldWidth) + 0.018,
            height: CGFloat(browserWorldHeight) + 0.018,
            length: 0.006,
            chamferRadius: 0.004
        )
        let frameMaterial = SCNMaterial()
        frameMaterial.lightingModel = .constant
        frameMaterial.diffuse.contents = UIColor(white: 0.10, alpha: 1)
        frameMaterial.emission.contents = UIColor(white: 0.10, alpha: 1)
        frameGeometry.firstMaterial = frameMaterial
        browserFrameGeometry = frameGeometry
        let frameNode = browserFrameNode
        frameNode.geometry = frameGeometry
        frameNode.isHidden = true
        frameNode.position = SCNVector3(0, 0, -0.005)
        browserPlaneNode.addChildNode(frameNode)

        // Ручка внизу — подсказка, за что тянуть.
        let handleGeometry = SCNBox(
            width: CGFloat(browserWorldWidth) * 0.3,
            height: 0.012,
            length: 0.006,
            chamferRadius: 0.005
        )
        let handleMaterial = SCNMaterial()
        handleMaterial.lightingModel = .constant
        handleMaterial.diffuse.contents = UIColor(white: 0.45, alpha: 1)
        handleMaterial.emission.contents = UIColor(white: 0.45, alpha: 1)
        handleGeometry.firstMaterial = handleMaterial
        let handleNode = SCNNode(geometry: handleGeometry)
        handleNode.position = SCNVector3(0, -Double(browserWorldHeight) * 0.5 - 0.028, 0)
        browserPlaneNode.addChildNode(handleNode)
        browserHandleNode = handleNode
    }

    /// A site's fullscreen request stays inside its spatial window. The hall
    /// is an explicit, separate app; playing a movie must not resize the desktop.
    private func setCinemaMode(_ active: Bool) {
        guard inVR, !cinemaActive, !panoramaActive, !graffitiActive, !directVideoActive else { return }
        isCinemaMode = false
        if active, let url = browser.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            openExternalPage(url)
        }
    }

    private func isDirectVideoSite(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host.contains("youtube-nocookie.com") || host.contains("youtu.be") || host.contains("tiktok.com")
    }

    private func buildToolbar() {
        var items: [ToolbarItem] = [
            ToolbarItem(title: "Домой", action: .home),
            ToolbarItem(title: "Назад", action: .back),
            ToolbarItem(title: "Обновить", action: .reload),
            ToolbarItem(title: "Центр", action: .center),
            ToolbarItem(title: "Размер", action: .size)
        ]

        let gap: Float = 0.014
        let count = Float(items.count)
        let buttonWidth = min(0.42, (browserWorldWidth - gap * (count - 1)) / count)
        toolbarCenterY = -browserWorldHeight * 0.5 - 0.085 - toolbarButtonHeight * 0.5

        for index in items.indices {
            let minX = -(buttonWidth * count + gap * (count - 1)) * 0.5 + Float(index) * (buttonWidth + gap)
            items[index].minX = minX
            items[index].maxX = minX + buttonWidth

            let plane = SCNPlane(
                width: CGFloat(buttonWidth),
                height: CGFloat(toolbarButtonHeight)
            )
            plane.cornerRadius = CGFloat(toolbarButtonHeight) * 0.28
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            let normal = Self.buttonImage(title: items[index].title, highlighted: false)
            let highlighted = Self.buttonImage(title: items[index].title, highlighted: true)
            toolbarImages.append((normal, highlighted))
            material.diffuse.contents = normal
            material.emission.contents = material.diffuse.contents
            plane.firstMaterial = material

            let node = SCNNode(geometry: plane)
            node.position = SCNVector3(
                Double(minX + buttonWidth * 0.5),
                Double(toolbarCenterY),
                0.003
            )
            toolbarNode.addChildNode(node)
            toolbarButtonNodes.append(node)
        }

        linkItems = items
        browserPlaneNode.addChildNode(toolbarNode)
    }

    /// Текстура кнопки. Рисуем заранее — в VR нет места для UIKit-слоёв.
    private static func buttonImage(title: String, highlighted: Bool) -> UIImage {
        let size = CGSize(width: 320, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // 320 physical pixels already exceed the projected button size.
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 54)
            let background = highlighted
                ? UIColor(white: 0.92, alpha: 0.95)
                : UIColor(white: 0.38, alpha: 0.78)
            background.setFill()
            path.fill()

            UIColor(white: highlighted ? 1.0 : 0.85, alpha: 0.45).setStroke()
            path.lineWidth = 4
            path.stroke()

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 46, weight: .semibold),
                .foregroundColor: highlighted ? UIColor.black : UIColor.white,
                .paragraphStyle: style
            ]
            let textSize = title.size(withAttributes: attributes)
            let textRect = CGRect(
                x: 0,
                y: (size.height - textSize.height) * 0.5,
                width: size.width,
                height: textSize.height
            )
            title.draw(in: textRect, withAttributes: attributes)
            _ = context
        }
    }

    private static let handSkeletonBonePairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP)
    ]

    private func buildHandSkeleton() {
        buildSingleHandSkeleton(root: leftHandSkeletonNode, joints: &leftSkeletonJoints, bones: &leftSkeletonBones, palm: &leftPalmNode, color: UIColor(red: 0.35, green: 0.90, blue: 1.0, alpha: 1))
        buildSingleHandSkeleton(root: rightHandSkeletonNode, joints: &rightSkeletonJoints, bones: &rightSkeletonBones, palm: &rightPalmNode, color: UIColor(red: 1.0, green: 0.58, blue: 0.32, alpha: 1))
        leftHandSkeletonNode.renderingOrder = 220
        rightHandSkeletonNode.renderingOrder = 220
        leftHandSkeletonNode.isHidden = true
        rightHandSkeletonNode.isHidden = true
        worldScene.rootNode.addChildNode(leftHandSkeletonNode)
        worldScene.rootNode.addChildNode(rightHandSkeletonNode)
    }

    private func buildSingleHandSkeleton(
        root: SCNNode,
        joints: inout [VNHumanHandPoseObservation.JointName: SCNNode],
        bones: inout [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, SCNNode)],
        palm: inout SCNNode?,
        color: UIColor
    ) {
        let jointMaterial = SCNMaterial()
        jointMaterial.lightingModel = .constant
        jointMaterial.diffuse.contents = color
        jointMaterial.emission.contents = color
        jointMaterial.readsFromDepthBuffer = false
        jointMaterial.writesToDepthBuffer = false

        let boneMaterial = jointMaterial.copy() as! SCNMaterial

        // Ладонь — приплюснутый эллипсоид, ориентируется вдоль wrist→middleMCP.
        let palmGeometry = SCNSphere(radius: 1)
        palmGeometry.segmentCount = 20
        palmGeometry.firstMaterial = jointMaterial.copy() as? SCNMaterial
        let palmNode = SCNNode(geometry: palmGeometry)
        palmNode.renderingOrder = 219
        palmNode.isHidden = true
        root.addChildNode(palmNode)
        palm = palmNode

        // Радиусы суставов по месту — у запястья толще, к кончикам тоньше.
        let jointRadius: [VNHumanHandPoseObservation.JointName: CGFloat] = [
            .wrist: 0.015,
            .thumbCMC: 0.011, .thumbMP: 0.010, .thumbIP: 0.0085, .thumbTip: 0.009,
            .indexMCP: 0.012, .indexPIP: 0.0095, .indexDIP: 0.008, .indexTip: 0.0085,
            .middleMCP: 0.012, .middlePIP: 0.0095, .middleDIP: 0.008, .middleTip: 0.0085,
            .ringMCP: 0.011, .ringPIP: 0.009, .ringDIP: 0.0076, .ringTip: 0.0082,
            .littleMCP: 0.0095, .littlePIP: 0.0078, .littleDIP: 0.0066, .littleTip: 0.0074
        ]

        let jointNames: [VNHumanHandPoseObservation.JointName] = [
            .wrist,
            .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip
        ]

        for jointName in jointNames {
            let sphere = SCNSphere(radius: jointRadius[jointName] ?? 0.009)
            sphere.segmentCount = 12
            sphere.firstMaterial = jointMaterial.copy() as? SCNMaterial
            let node = SCNNode(geometry: sphere)
            node.renderingOrder = 221
            node.isHidden = true
            root.addChildNode(node)
            joints[jointName] = node
        }

        func boneRadius(
            _ a: VNHumanHandPoseObservation.JointName,
            _ b: VNHumanHandPoseObservation.JointName
        ) -> CGFloat {
            if a == .wrist { return 0.0055 }
            let distal: Set<VNHumanHandPoseObservation.JointName> = [.indexTip, .middleTip, .ringTip, .littleTip, .thumbTip]
            let mid: Set<VNHumanHandPoseObservation.JointName> = [.indexDIP, .middleDIP, .ringDIP, .littleDIP, .thumbIP]
            if distal.contains(b) { return 0.0040 }
            if mid.contains(b) { return 0.0050 }
            return 0.0062
        }

        for (a, b) in Self.handSkeletonBonePairs {
            let cylinder = SCNCylinder(radius: boneRadius(a, b), height: 1.0)
            cylinder.radialSegmentCount = 10
            cylinder.firstMaterial = boneMaterial.copy() as? SCNMaterial
            let node = SCNNode(geometry: cylinder)
            node.renderingOrder = 220
            node.isHidden = true
            root.addChildNode(node)
            bones.append((a, b, node))
        }
    }

    private func buildPointer() {
        // Луч. Цилиндр вытягивается по длине каждый кадр.
        let rayGeometry = SCNCylinder(radius: 0.0032, height: 1)
        rayGeometry.radialSegmentCount = 8
        let rayMaterial = SCNMaterial()
        rayMaterial.lightingModel = .constant
        rayMaterial.diffuse.contents = UIColor(red: 0.38, green: 0.86, blue: 1.0, alpha: 1)
        rayMaterial.emission.contents = UIColor(red: 0.38, green: 0.86, blue: 1.0, alpha: 1)
        rayMaterial.transparency = 0.55
        rayMaterial.writesToDepthBuffer = false
        rayMaterial.readsFromDepthBuffer = false
        rayGeometry.firstMaterial = rayMaterial
        rayNode.geometry = rayGeometry
        rayNode.renderingOrder = 90
        rayNode.isHidden = true
        worldScene.rootNode.addChildNode(rayNode)

        // Точка попадания: диск плюс кольцо вокруг.
        let dotGeometry = SCNCylinder(radius: 0.009, height: 0.0012)
        dotGeometry.radialSegmentCount = 24
        let dotMaterial = SCNMaterial()
        dotMaterial.lightingModel = .constant
        dotMaterial.diffuse.contents = UIColor.white
        dotMaterial.emission.contents = UIColor.white
        dotMaterial.writesToDepthBuffer = false
        dotMaterial.readsFromDepthBuffer = false
        dotGeometry.firstMaterial = dotMaterial
        pointerDotNode.geometry = dotGeometry

        let ringGeometry = SCNTorus(ringRadius: 0.019, pipeRadius: 0.0022)
        ringGeometry.ringSegmentCount = 36
        ringGeometry.pipeSegmentCount = 8
        let ringMaterial = SCNMaterial()
        ringMaterial.lightingModel = .constant
        ringMaterial.diffuse.contents = UIColor(red: 0.38, green: 0.86, blue: 1.0, alpha: 1)
        ringMaterial.emission.contents = UIColor(red: 0.38, green: 0.86, blue: 1.0, alpha: 1)
        ringMaterial.transparency = 0.9
        ringMaterial.writesToDepthBuffer = false
        ringMaterial.readsFromDepthBuffer = false
        ringGeometry.firstMaterial = ringMaterial
        pointerRingNode.geometry = ringGeometry

        pointerNode.addChildNode(pointerDotNode)
        pointerNode.addChildNode(pointerRingNode)
        pointerNode.renderingOrder = 95
        pointerNode.isHidden = true
        worldScene.rootNode.addChildNode(pointerNode)
    }

    /// Пересчитывает IPD и матрицы проекции под текущий профиль шлема.
    private func fullEyeFrustum(eye: Int, aspect: Float) -> EyeFrustum {
        let base=VRLensMath.frustum(eye:eye,profile:profile)
        let scale=VRLensMath.renderScale(profile:profile,aspect:aspect)
        return EyeFrustum(left:base.left*scale,right:base.right*scale,
                          bottom:base.bottom*scale,top:base.top*scale)
    }

    private func applyEyeGeometry() {
        // Monoscopic mode requested by the user: no per-eye baseline/parallax.
        leftCameraNode.simdPosition = .zero

        let near: Float = 0.02
        let far: Float = 100
        let aspect = Float(view.bounds.width * 0.5 / max(view.bounds.height, 1))
        let left = fullEyeFrustum(eye: 0, aspect: aspect)
        tracking.setCameraCoverage(x: Double(max(abs(left.left), abs(left.right))),
                                   y: Double(max(abs(left.bottom), abs(left.top))))
        leftCameraNode.camera?.projectionTransform = VRLensMath.projection(left, near: near, far: far)
    }

    private func configureDirectVideoStage() {
        directVideoStage.backgroundColor = .clear
        directVideoStage.isOpaque = false
        directVideoStage.clipsToBounds = true
        liveWebReplicator.backgroundColor = .clear
        liveWebReplicator.isOpaque = false
        directVideoStage.addSubview(liveWebReplicator)
        let source = cinemaEyeContainers[0]
        source.backgroundColor = .clear
        source.isOpaque = false
        source.clipsToBounds = true
        liveWebReplicator.addSubview(source)
        // Only ONE WKWebView/player. Core Animation copies this layer subtree.
        directVideoLeft = makeDirectVideoWebView(role: "left")
        source.addSubview(directVideoLeft)
        for pointer in cinemaWebPointers {
            pointer.bounds = CGRect(x:0,y:0,width:10,height:10)
            pointer.backgroundColor = .white
            pointer.layer.cornerRadius = 5
            pointer.layer.borderColor = UIColor(white:0.3,alpha:1).cgColor
            pointer.layer.borderWidth = 1
            pointer.isUserInteractionEnabled = false
            pointer.isHidden = true
            directVideoStage.addSubview(pointer)
        }
        let label=UILabel()
        label.textColor = .white
        label.backgroundColor = UIColor(white:0.1,alpha:0.88)
        label.font = .systemFont(ofSize:22,weight:.medium)
        label.textAlignment = .center
        label.numberOfLines = 3
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.isUserInteractionEnabled = false
        directVideoLeft.addSubview(label)
        directVideoStatusLabels = [label]
    }

    private func makeDirectVideoWebView(role: String) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        // V83+ has ONE audible source; the other eye is only a layer copy.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.preferences.isElementFullscreenEnabled = false
        config.websiteDataStore = browser.configuration.websiteDataStore
        config.processPool = browser.configuration.processPool

        let ucc = WKUserContentController()
        if let path = Bundle.main.path(forResource: "WebInput", ofType: "js"),
           let js = try? String(contentsOfFile: path, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        ucc.addUserScript(WKUserScript(
            source: Self.directVideoRoleScript(role: role),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        ucc.add(WeakScriptMessageHandler(self), name: "handarFeedback")
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = true
        webView.alpha = 1
        webView.isHidden = false
        webView.layer.masksToBounds = false
        webView.layer.cornerRadius = 0
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = nil
        return webView
    }

    private static func directVideoRoleScript(role: String) -> String {
        let muted = role == "right" ? "true" : "false"
        return """
        (function(){
          window.__handarDirectRole = '\(role)';
          window.__handarDirectMuted = \(muted);
          var wanted=true, blocked=false, pending=false, lastPlay=-Infinity, lastSeek=-Infinity;
          var configured=new WeakSet(),soundAttempted=new WeakSet(),surfaceVideo=null;
          function video(){
            var all=[].slice.call(document.querySelectorAll('video'));
            all.sort(function(a,b){return (b.clientWidth*b.clientHeight)-(a.clientWidth*a.clientHeight);});
            return all[0]||null;
          }
          function pageError(){
            var node=document.querySelector('.ytp-error-content-wrap,ytm-player-error-message-renderer,yt-player-error-message-renderer');
            if(!node)return null;
            var rect=node.getBoundingClientRect(),css=window.getComputedStyle(node);
            if(rect.width<=0||rect.height<=0||css.display==='none'||css.visibility==='hidden'||css.opacity==='0')return null;
            var text=(node.innerText||node.textContent||'').trim();
            return text ? text.slice(0,240) : null;
          }
          function configure(v){
            if(!v)return;
            if(!configured.has(v)){
              configured.add(v);
              v.setAttribute('playsinline','');v.setAttribute('webkit-playsinline','');v.playsInline=true;
            }
            // Muting the slave is mandatory before play(). Never repeatedly unmute
            // the master: WebKit can pause playback when mute changes without a gesture.
            if(window.__handarDirectMuted){
              if(!v.muted)v.muted=true;
              if(!v.defaultMuted)v.defaultMuted=true;
              if(v.volume!==0)v.volume=0;
            }
          }
          window.__handarSetPlaybackIntent=function(playing){
            wanted=!!playing;blocked=false;
            if(wanted)lastPlay=-Infinity;
          };
          function ensurePlaying(v,explicit){
            if(window.__handarBrowseOnly&&!window.__handarDirectMuted&&!explicit)return;
            if(!v||!wanted||blocked||document.hidden||v.ended||v.error||pending||!v.paused)return;
            var now=Date.now();if(now-lastPlay<1500)return;lastPlay=now;
            configure(v);pending=true;
            function failed(e){pending=false;if(e&&e.name==='NotAllowedError')blocked=true;}
            try{var p=v.play();if(p&&p.then)p.then(function(){pending=false;},failed);else pending=false;}catch(e){failed(e)}
          }
          window.__handarTuneDirectVideo=function(){
            if(window.__handarDirectMuted)document.querySelectorAll('audio').forEach(configure);
            var v=video();
            if(v)configure(v);
            var show=!!(window.__handarCinemaSurface&&v&&!v.error&&!pageError()&&v.readyState>=2&&(!v.paused||v.currentTime>0));
            if(surfaceVideo && (surfaceVideo!==v || !show))surfaceVideo.removeAttribute('data-handar-cinema-video');
            surfaceVideo=show?v:null;
            if(!show){
              document.documentElement.classList.remove('handar-cinema-surface');
              return;
            }
            if(show){
              v.setAttribute('data-handar-cinema-video','');
              document.documentElement.classList.add('handar-cinema-surface');
              if(!window.__handarDirectMuted&&!window.__handarVolumeChosen&&!v.paused&&!soundAttempted.has(v)){
                soundAttempted.add(v);
                if(window.__handarEnableAudio)window.__handarEnableAudio(true);
              }
            }
          };
          window.__handarDirectPlay=function(){
            var v=video(); if(!v) return;
            window.__handarSetPlaybackIntent(true);configure(v);
            if(!window.__handarDirectMuted){
              if(window.__handarEnableAudio)window.__handarEnableAudio(false);
              else {if(v.muted)v.muted=false;if(v.volume<=0)v.volume=0.65;}
            }
            ensurePlaying(v,true);
          };
          window.__handarEnsureDirectVideo=function(){
            window.__handarTuneDirectVideo();ensurePlaying(video());
          };
          window.__handarDirectState=function(){
            var error=pageError(),v=video();if(!v)return JSON.stringify({missing:true,e:error});
            return JSON.stringify({t:v.currentTime||0,p:v.paused,w:wanted&&!v.ended,b:blocked,
              s:v.playbackRate||1,r:v.readyState,d:Number.isFinite(v.duration)?v.duration:0,
              q:!!v.seeking,a:Date.now(),m:!!v.muted,v:v.volume,e:error||(v.error?(v.error.message||"Ошибка видеоплеера"):null)});
          };
          window.__handarSyncDirectVideo=function(master){
            var v=video();if(!v||!master)return;configure(v);
            wanted=window.__handarBrowseOnly ? !master.p&&!master.b : !!master.w&&!master.b;
            var baseRate=Number.isFinite(master.s)&&master.s>0?master.s:1;
            if(!wanted){if(v.playbackRate!==baseRate)v.playbackRate=baseRate;if(!v.paused)v.pause();return;}
            var now=Date.now();
            // Independent pages can be in different ads or buffer windows. Seek
            // only matching loaded timelines and allow the previous seek to settle.
            var sameTimeline=master.d>0&&Number.isFinite(v.duration)&&Math.abs(v.duration-master.d)<2;
            // Both WebKit processes use the same wall clock. Compensate for the
            // JS/native/JS round trip instead of chasing an already old position.
            var age=Number.isFinite(master.a)?(now-master.a)/1000:0;
            var ready=sameTimeline&&master.r>=3&&v.readyState>=3&&!master.p&&!master.q&&!v.seeking&&age>=0&&age<0.75;
            var target=master.t+(ready?age*baseRate:0), rate=baseRate;
            if(ready&&Number.isFinite(target)){
              var ranges=v.seekable,available=false;
              for(var i=0;ranges&&i<ranges.length;i++)if(target>=ranges.start(i)&&target<=ranges.end(i))available=true;
              var drift=target-v.currentTime;
              if(available&&Math.abs(drift)>0.45&&now-lastSeek>=2000){
                try{v.currentTime=target;lastSeek=now;}catch(e){}
              }else if(available&&Math.abs(drift)>0.035){
                // Small drift is corrected without repeatedly flushing buffers.
                rate=baseRate*(1+Math.max(-0.10,Math.min(0.10,drift*0.6)));
              }
            }
            if(Math.abs(v.playbackRate-rate)>0.001)v.playbackRate=rate;
            ensurePlaying(v);
          };
          // Preserve explicit pauses from the site's own play/pause button too.
          document.addEventListener('click',function(event){
            if(!event.isTrusted&&!event.handarConfirmed)return;
            var target=event.target&&event.target.closest?event.target.closest('.ytp-play-button,button[aria-label],button[title]'):null;
            if(!target)return;
            var label=(target.getAttribute('aria-label')||target.getAttribute('title')||'');
            if(target.matches('.ytp-play-button')||/^(play|pause|воспроизвести|приостановить|пауза)/i.test(label)){
              var v=video();if(v)window.__handarSetPlaybackIntent(v.paused);
            }
          },true);
          var observer=new MutationObserver(function(changes){
            changes.forEach(function(change){change.addedNodes.forEach(function(node){
              if(node.nodeName==='VIDEO'||(window.__handarDirectMuted&&node.nodeName==='AUDIO'))configure(node);
              if(node.querySelectorAll)node.querySelectorAll(window.__handarDirectMuted?'video,audio':'video').forEach(configure);
            });});
          });
          observer.observe(document,{childList:true,subtree:true});
          var style=document.createElement('style');
          style.textContent='html.handar-cinema-surface,html.handar-cinema-surface body{background:#000!important;margin:0!important;}' +
            'html.handar-cinema-surface,html.handar-cinema-surface body{overflow:hidden!important;}' +
            '.handar-cinema-surface video[data-handar-cinema-video]{visibility:visible!important;position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;object-fit:contain!important;z-index:2147483646!important;}' +
            '.handar-cinema-surface .html5-video-player,.handar-cinema-surface .html5-video-container{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;}';
          function installStyle(){var parent=document.head||document.documentElement;if(parent)parent.appendChild(style);else requestAnimationFrame(installStyle);}
          installStyle();
          setInterval(window.__handarEnsureDirectVideo,1000);
          setTimeout(window.__handarEnsureDirectVideo,50);
          setTimeout(window.__handarEnsureDirectVideo,600);
          window.addEventListener('pagehide',function(){wanted=false;observer.disconnect();});
        })();
        """
    }

    private func layoutDirectVideoStage() {
        directVideoStage.frame=view.bounds
        liveWebReplicator.frame=directVideoStage.bounds
        if directVideoActive { updateCinemaWebScreen() }
    }

    private func navigateLiveBrowser(back: Bool) {
        releasePointer() // Keep the toolbar's dwell latch until the finger leaves.
        playUIConfirmation()
        liveProcessRecoveries.removeAll()
        if back {
            guard directVideoLeft.canGoBack else { return }
            directVideoLeft.goBack()
        } else {
            setDirectVideoNotice("Обновляю страницу…")
            directVideoLeft.reload()
        }
    }

    private func openExternalPage(_ url: URL) {
        guard inVR else { browser.load(URLRequest(url: url)); return }
        cancelHandInteraction()
        pauseAndMuteBrowserMedia()
        presentDirectVideoStage(url: url, browsing: true)
    }

    private func projectedCinemaCorner(_ local: SIMD3<Float>, eye: Int, using supplied: simd_float4x4? = nil) -> SIMD2<Double>? {
        guard let transform=supplied ?? liveWebTransform else { return nil }
        // One central camera, including the live page. Eye only controls alignment.
        let point=leftCameraNode.simdWorldTransform.inverse * (transform * SIMD4<Float>(local,1))
        let depth = -point.z
        guard depth > 0.03 else { return nil }
        let frustum=VRLensMath.frustum(eye:0,profile:profile)
        let source=SIMD2<Double>(Double((point.x/depth-frustum.left)/(frustum.right-frustum.left)),
                                 Double((frustum.top-point.y/depth)/(frustum.top-frustum.bottom)))
        let c=VRLensMath.lensCenterUV(eye:eye,profile:profile)
        let aspect=Double(view.bounds.width*0.5/max(view.bounds.height,1))
        guard let corrected=MonoViewGeometry.displayUV(source:source,center:SIMD2(Double(c.x),Double(c.y)),
            aspect:aspect,k1:Double(profile.k1),k2:Double(profile.k2)) else { return nil }
        return corrected*SIMD2(Double(view.bounds.width*0.5),Double(view.bounds.height))
    }

    private func updateCinemaWebScreen() {
        guard directVideoActive,liveWebTransform != nil,view.bounds.width>1,view.bounds.height>1 else {
            directVideoLeft?.isHidden=true
            cinemaScreenMappings=[nil,nil]
            updateCinemaWebPointers(nil)
            return
        }
        let halfWidth=view.bounds.width*0.5
        let sourceSize=cinemaWebScreenActive ? CGSize(width:960,height:540) : CGSize(width:1280,height:720)
        let w=liveWebSize.x*0.5,h=liveWebSize.y*0.5
        let localCorners=[SIMD3<Float>(-w,h,0.012),SIMD3<Float>(w,h,0.012),
                          SIMD3<Float>(w,-h,0.012),SIMD3<Float>(-w,-h,0.012)]
        let left=VRLensMath.lensCenterUV(eye:0,profile:profile),right=VRLensMath.lensCenterUV(eye:1,profile:profile)
        let shift=MonoViewGeometry.replicaShift(left:SIMD2(Double(left.x),Double(left.y)),right:SIMD2(Double(right.x),Double(right.y)),
            width:Double(view.bounds.width),height:Double(view.bounds.height))
        let viewport=MonoViewGeometry.sourceViewport(width:Double(view.bounds.width),height:Double(view.bounds.height),shift:shift)
        let frame=CGRect(x:CGFloat(viewport.origin.x),y:CGFloat(viewport.origin.y),width:CGFloat(viewport.size.x),height:CGFloat(viewport.size.y))
        CATransaction.begin();CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        liveWebReplicator.copyOffset=CGPoint(x:CGFloat(shift.x),y:CGFloat(shift.y))
        cinemaEyeContainers[0].frame=frame
        // Right frame is hit/visibility metadata, not a second content view.
        cinemaEyeContainers[1].frame=frame.offsetBy(dx:CGFloat(shift.x),dy:CGFloat(shift.y))
        let corners=localCorners.compactMap { projectedCinemaCorner($0,eye:0) }
        guard let mapping=CinemaScreenHomography(corners:corners) else {
            cinemaScreenMappings=[nil,nil];directVideoLeft.isHidden=true;updateCinemaWebPointers(nil);return
        }
        let rightCorners=corners.map { $0+SIMD2(shift.x-Double(halfWidth),shift.y) }
        cinemaScreenMappings=[mapping,CinemaScreenHomography(corners:rightCorners)]
        directVideoLeft.isHidden=false
        directVideoLeft.bounds=CGRect(origin:.zero,size:sourceSize)
        directVideoLeft.layer.anchorPoint = .zero
        directVideoLeft.layer.position=CGPoint(x:-frame.minX,y:-frame.minY)
        var transform=CATransform3DIdentity
        transform.m11=CGFloat(mapping.a)/sourceSize.width;transform.m21=CGFloat(mapping.b)/sourceSize.height;transform.m41=CGFloat(mapping.c)
        transform.m12=CGFloat(mapping.d)/sourceSize.width;transform.m22=CGFloat(mapping.e)/sourceSize.height;transform.m42=CGFloat(mapping.f)
        transform.m14=CGFloat(mapping.g)/sourceSize.width;transform.m24=CGFloat(mapping.h)/sourceSize.height
        directVideoLeft.layer.transform=transform
        directVideoStatusLabels[0].frame=CGRect(x:36,y:sourceSize.height-126,width:sourceSize.width-72,height:90)
        directVideoLeft.bringSubviewToFront(directVideoStatusLabels[0])
    }

    private func updateCinemaWebPointers(_ uv: CGPoint?) {
        for eye in 0..<2 {
            guard let uv, let mapping = cinemaScreenMappings[eye],
                  let point = mapping.map(SIMD2(Double(uv.x), Double(uv.y))) else {
                cinemaWebPointers[eye].isHidden = true
                continue
            }
            let position = CGPoint(x: CGFloat(point.x) + CGFloat(eye) * view.bounds.width * 0.5, y: CGFloat(point.y))
            cinemaWebPointers[eye].center = position
            cinemaWebPointers[eye].isHidden = !cinemaEyeContainers[eye].frame.contains(position)
        }
    }

    private func handleCinemaWebHands(left: HandSample?, right: HandSample?) {
        guard let sample = right ?? left else {
            handleCinemaRay(nil, down: false, allowBegin: false, dwell: usesDwell)
            return
        }
        handleCinemaRay(tracking.worldRay(visionPoint: sample.indexTip), down: sample.clickPinch,
                        allowBegin: sample.clickBegan, dwell: usesDwell)
    }

    private func setDirectVideoNotice(_ message: String) {
        for label in directVideoStatusLabels {
            label.text = message
            label.isHidden = message.isEmpty
        }
    }

    private func closeDirectVideo() {
        playUIConfirmation()
        if cinemaActive { exitCinema() }
        else {
            hideDirectVideoStage()
            isCinemaMode = false
            openVRDesktop()
            startBrowserCapture()
        }
    }

    private func presentDirectVideoStage(url: URL, browsing: Bool = false) {
        liveBrowserActive = browsing
        liveProcessRecoveries.removeAll()
        liveLoadError = nil
        cinemaWebLoadStartedAt = CACurrentMediaTime()
        setCinemaWebRecovery(false)
        // This flag is installed before page scripts, and persists across navigation.
        for webView in [directVideoLeft!] {
            let controller = webView.configuration.userContentController
            let scripts = controller.userScripts.filter { !$0.source.hasPrefix("window.__handarBrowseOnly=") }
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(source: "window.__handarBrowseOnly=\(browsing ? "true" : "false");window.__handarCinemaSurface=\(browsing ? "false" : "true");", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            for script in scripts { controller.addUserScript(script) }
            webView.backgroundColor = browsing ? .systemBackground : .black
            webView.scrollView.backgroundColor = webView.backgroundColor
        }
        directVideoGeneration = UUID()
        directVideoSyncInFlight = false
        stopBrowserCapture()
        // Keep camera, world, frame and toolbar rendering behind the live window.
        vrView?.isPaused = false
        directVideoStage.backgroundColor = .clear
        directVideoStage.isOpaque = false
        if !cinemaActive {
            applySpatialSurface(home: false, transparent: false)
            browserPlaneNode.geometry = nil // Hide the stale snapshot, keep its children.
            browserHandleNode.isHidden = false
            toolbarNode.isHidden = false
            isCinemaMode = false
        }
        directVideoURL = url
        setDirectVideoNotice("Загружаю страницу…")
        directVideoActive = true
        directVideoStage.isHidden = false
        layoutDirectVideoStage()
        view.bringSubviewToFront(directVideoStage)

        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        directVideoLeft.load(request)

        directVideoSyncTimer?.invalidate()
        directVideoSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.syncDirectVideoEyes()
        }
        if let timer = directVideoSyncTimer { RunLoop.main.add(timer, forMode:.common) }
    }

    private func hideDirectVideoStage() {
        directVideoGeneration = UUID()
        directVideoSyncInFlight = false
        vrView?.isPaused = !inVR
        directVideoActive = false
        setCinemaWebRecovery(false)
        browserPlaneNode.geometry = browserPlaneGeometry
        liveBrowserActive = false
        cinemaScreenMappings = [nil, nil]
        updateCinemaWebPointers(nil)
        directVideoSyncTimer?.invalidate()
        directVideoSyncTimer = nil
        directVideoStage.isHidden = true
        liveWebReplicator.alpha = 1
        liveWebReplicator.layer.mask = nil
        directVideoURL = nil
        directLeftInput.release(webView: directVideoLeft)
        pauseAndMute(directVideoLeft)
        directVideoLeft?.stopLoading()
    }

    private func activateMediaAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Playback already supports A2DP. Its explicit option is invalid
            // for an output-only category and can reject the whole session.
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            mediaAudioSessionActive = true
        } catch {
            mediaAudioSessionActive = false
            NSLog("HandAR media audio session: %@", error.localizedDescription)
        }
    }

    private func deactivateMediaAudioSession() {
        guard mediaAudioSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        mediaAudioSessionActive = false
    }

    private func pauseAndMuteBrowserMedia() {
        pauseAndMute(browser)
    }

    private func pauseAndMute(_ webView: WKWebView?) {
        webView?.evaluateJavaScript("if(window.__handarSetPlaybackIntent)window.__handarSetPlaybackIntent(false);document.querySelectorAll('video,audio').forEach(function(v){try{v.muted=true;v.pause();}catch(e){}});", completionHandler: nil)
    }

    private func activateDirectVideoAudio() {
        // A previous activation flag may be stale after an iOS interruption.
        activateMediaAudioSession()
    }

    // The legacy name remains at cinema control call sites. This polls ONE
    // player for progress/status; there is no second clock to synchronize.
    private func syncDirectVideoEyes() {
        guard directVideoActive,!directVideoSyncInFlight else { return }
        let generation=directVideoGeneration
        directVideoSyncInFlight=true
        directVideoLeft.evaluateJavaScript("window.__handarDirectState ? window.__handarDirectState() : 'null';") { [weak self] result,_ in
            guard let self,self.directVideoActive,self.directVideoGeneration==generation else { return }
            defer { self.directVideoSyncInFlight=false }
            guard let raw=result as? String,let data=raw.data(using:.utf8),
                  let state=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {
                self.updateCinemaWebWaiting()
                return
            }
            if let error = self.liveLoadError {
                self.setDirectVideoNotice(error); self.setCinemaWebRecovery(true); return
            }
            if let error = state["e"] as? String, !error.isEmpty {
                self.setDirectVideoNotice(error + (self.cinemaWebScreenActive ? "\nНа пульте: «Обновить»." : ""))
                self.setCinemaWebRecovery(true); return
            }
            guard let time=state["t"] as? Double,time.isFinite,let paused=state["p"] as? Bool else {
                self.updateCinemaWebWaiting(); return
            }
            if state["b"] as? Bool == true {
                self.setCinemaWebRecovery(false)
                self.setDirectVideoNotice("Нажми «Смотреть» на пульте для продолжения видео")
                return
            }
            if (state["r"] as? Int ?? 0) < 2 {
                self.updateCinemaWebWaiting(); return
            }
            self.cinemaWebLoadStartedAt = CACurrentMediaTime()
            self.setCinemaWebRecovery(false)
            if self.cinemaWebScreenActive,AVAudioSession.sharedInstance().outputVolume<=0 {
                self.setDirectVideoNotice("Увеличь громкость кнопками iPhone")
            }
            else if self.cinemaWebScreenActive,!paused,
                    (state["m"] as? Bool==true || (state["v"] as? Double ?? 1)<=0) {
                self.setDirectVideoNotice("Звук выключен. Нажми «Вкл звук» под экраном")
            }
            else if !paused,(state["r"] as? Int ?? 0)>=2 { self.setDirectVideoNotice("") }
            self.cinemaHall.setSoundEnabled(state["m"] as? Bool != true && (state["v"] as? Double ?? 1)>0)
            self.cinemaHall.setPlayingState(!paused)
            self.cinemaHall.setTime(current:time,duration:state["d"] as? Double ?? 0)
        }
    }

    private func setCinemaWebRecovery(_ required: Bool) {
        cinemaWebRecoveryRequired = cinemaWebScreenActive && required
        cinemaHall.setReloadAvailable(cinemaWebRecoveryRequired)
    }

    private func updateCinemaWebWaiting() {
        guard cinemaWebScreenActive else { return }
        if let error = liveLoadError {
            setDirectVideoNotice(error); setCinemaWebRecovery(true)
        } else if CACurrentMediaTime() - cinemaWebLoadStartedAt >= 20 {
            setDirectVideoNotice("Видео ещё не загрузилось. Выбери ролик на странице или нажми «Обновить» на пульте.")
            setCinemaWebRecovery(true)
        }
    }

    private func retryCinemaWebVideo() {
        guard cinemaWebScreenActive, let url = directVideoLeft.url ?? directVideoURL ?? cinemaOriginalURL else { return }
        cancelHandInteraction()
        handOwnership.suppressUntilOpen()
        presentDirectVideoStage(url: url)
    }

    private func removeDirectVideoMessageHandlers() {
        directVideoLeft?.configuration.userContentController.removeScriptMessageHandler(forName: "handarFeedback")
    }

    private func configureBrowser() {
        browser.navigationDelegate = self
        browser.uiDelegate = self
        // WebInput.js следит за плеером страницы и шлёт сюда true/false,
        // когда видео на YouTube/TikTok разворачивается на весь экран —
        // это и включает кинорежим.
        browser.configuration.userContentController.add(WeakScriptMessageHandler(self), name: "handarVideo")
        browser.configuration.userContentController.add(WeakScriptMessageHandler(self), name: "handarApp")
        browser.configuration.userContentController.add(WeakScriptMessageHandler(self), name: "handarSystem")
        browser.configuration.userContentController.add(WeakScriptMessageHandler(self), name: "handarFeedback")
        browser.loadHTMLString(Self.vrDesktopHTML, baseURL: URL(string: "https://handar.vision/") )
    }

    private func buildInterface() {
        // Браузер живёт под VR-выводом: ему нужен настоящий размер и окно,
        // иначе takeSnapshot отдаёт пустоту.
        view.addSubview(browser)
        if vrView != nil {
            view.addSubview(vrView)
        }
        configureDirectVideoStage()
        view.addSubview(directVideoStage)
        directVideoStage.isHidden = true
        directVideoStage.isUserInteractionEnabled = true

        menu = MainMenuView(frame: view.bounds, profile: profile)
        menu.onEnter = { [weak self] in
            self?.requestCameraAndEnterVR()
        }
        menu.onCalibration = { [weak self] in self?.startLensCalibration() }
        menu.onProfileChange = { [weak self] updated in
            guard let self else { return }
            self.profile = updated
            self.applyEyeGeometry()
        }
        menu.onDiagnostics = { [weak self] in
            self?.showVRBoxDiagnostics()
        }
        menu.onCinema = { [weak self] text in
            guard let self else { return }
            self.enterCinema(url: self.cinemaURL(from: text))
        }
        view.addSubview(menu)

        // Внутри VR экран не для пальцев, поэтому жестов ровно два.
        let recenter = UITapGestureRecognizer(target: self, action: #selector(handleRecenterTap))
        recenter.numberOfTouchesRequired = 1
        vrView?.addGestureRecognizer(recenter)

        let exit = UITapGestureRecognizer(target: self, action: #selector(handleExitTap))
        exit.numberOfTouchesRequired = 2
        vrView?.addGestureRecognizer(exit)

        setVRVisible(false)
    }

    private func layoutViews() {
        let bounds = view.bounds
        vrView?.frame = bounds
        menu?.frame = bounds
        lensCalibrationView?.frame = bounds

        // Внутренний WKWebView рендерим в фиксированном 16:9, чтобы
        // снимок страницы не превращался в квадрат. Сам VR-вывод при этом
        // занимает 100% физического экрана.
        let browserWidth: CGFloat = 1280
        let browserHeight: CGFloat = 720
        browser.frame = CGRect(
            x: (bounds.width - browserWidth) * 0.5,
            y: (bounds.height - browserHeight) * 0.5,
            width: browserWidth,
            height: browserHeight
        )
    }

    private func wireServices() {
        tracking.onFrame = { [weak self] pixelBuffer, orientation in
            guard let self, self.inVR else { return }
            if !self.usesHeadAim || self.lensCalibrationView != nil || self.graffitiActive {
                self.hands.process(pixelBuffer: pixelBuffer, orientation: orientation)
            }
        }

        let cameraDelivery = LatestMainDelivery<CameraFrame> { [weak self] frame in
            guard let self, self.inVR, self.tracking.isCurrent(frame) else { return }
            self.headNode.simdTransform = self.tracking.headTransform(frame)
            self.timeMotionHeadTimestamp = frame.timestamp; self.timeMotionHeadMode = frame.mode
            if self.cinemaActive, self.cinemaNeedsAlignment {
                self.alignCinemaToCurrentPose()
            }
            if self.graffitiActive, self.graffitiTrackingReady { self.graffiti.align(head: self.headNode) }
            self.ensureBrowserAnchor(using: frame.camera.transform)
        }
        tracking.onCamera = { frame in cameraDelivery.submit(frame) }

        tracking.onAnchorUpdate = { [weak self] anchor in
            DispatchQueue.main.async {
                if let self, self.graffitiActive { self.graffiti.update(anchor: anchor) }
                // В зале экран держит CinemaHall — якорь панели не трогаем.
                guard let self, self.inVR, !self.isDragging, !self.cinemaActive else { return }
                guard self.browserAnchor?.identifier == anchor.identifier else { return }
                self.browserAnchor = anchor
                self.browserWorldTransform = anchor.transform
                self.applyBrowserWorldTransform()
            }
        }

        tracking.onFailure = { [weak self] message in
            self?.leaveVRToMenu()
            self?.showAlert(message)
        }

        controller.onConnectionChanged = { [weak self] connected, _ in
            DispatchQueue.main.async {
                self?.controllerConnected = connected
                self?.updateVRDesktopStatus()
                if !connected {
                    guard let self else { return }
                    self.controllerHandRoot.isHidden = true
                    self.controllerButtonDown = false
                    self.input.release(webView: self.browser)
                }
            }
        }

        controller.onStick = { [weak self] x, y in
            DispatchQueue.main.async {
                self?.handleControllerStick(x: x, y: y)
            }
        }

        controller.onGyro = { [weak self] rate in
            DispatchQueue.main.async {
                self?.handleControllerGyro(rate)
            }
        }

        controller.onButton = { [weak self] button, pressed in
            DispatchQueue.main.async {
                self?.handleControllerButton(button, pressed: pressed)
            }
        }

        controller.onMotion = { [weak self] hasGyro, _ in
            guard hasGyro else { return }
            // Для будущего 6DoF-профиля сохраняем сам факт motion; текущая
            // виртуальная рука использует стик как надёжный 2D-позиционер.
            self?.controllerConnected = true
        }

        let handDelivery = LatestMainDelivery<(HandSample?, HandSample?)> { [weak self] samples in
            guard let self, self.inVR else { return }
            self.handleHands(left: samples.0, right: samples.1)
        }
        hands.onUpdate = { left, right in handDelivery.submit((left, right)) }
    }

    // MARK: Вход и выход

    private func requestCameraAndEnterVR(afterEnter: (() -> Void)? = nil) {
        guard !inVR else { return }
        guard compositor != nil else {
            showAlert("Не удалось инициализировать VR-рендер.")
            return
        }
        guard ARWorldTrackingConfiguration.isSupported else {
            showAlert("Этот iPhone не поддерживает ARKit World Tracking.")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            enterVR()
            afterEnter?()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if allowed {
                        self.enterVR()
                        afterEnter?()
                    } else {
                        self.showAlert("Нужен доступ к задней камере для VR.")
                    }
                }
            }
        case .denied, .restricted:
            showAlert("Разреши камеру в Настройки → HandAR Vision → Камера.")
        @unknown default:
            showAlert("Не удалось проверить доступ к камере.")
        }
    }

    private func startLensCalibration() {
        guard lensCalibrationView == nil, !cinemaActive, !securityGameActive, !panoramaActive, !graffitiActive else { return }
        let wasInVR=inVR
        let present: () -> Void = { [weak self] in
            guard let self,self.inVR else { return }
            self.returnToMenuAfterCalibration = !wasInVR
            self.cancelHandInteraction()
            self.controllerButtonDown=false
            self.stopBrowserCapture()
            self.vrView?.isPaused=true
            let calibration=LensCalibrationView(frame:self.view.bounds,profile:self.profile)
            calibration.onChange={ [weak self] updated in
                guard let self else {return}
                self.profile=updated;self.applyEyeGeometry();self.menu.updateProfile(updated)
            }
            calibration.onInteraction={ [weak self] in self?.playUIConfirmation() }
            calibration.onFinish={ [weak self] in self?.finishLensCalibration() }
            self.lensCalibrationView=calibration
            self.view.addSubview(calibration)
        }
        if inVR {present()} else {requestCameraAndEnterVR(afterEnter:present)}
    }

    private func finishLensCalibration() {
        lensCalibrationView?.cancelInteraction()
        lensCalibrationView?.removeFromSuperview()
        lensCalibrationView=nil
        controllerButtonDown=false
        cancelHandInteraction()
        profile.save();applyEyeGeometry();menu.updateProfile(profile)
        if returnToMenuAfterCalibration {returnToMenuAfterCalibration=false;leaveVRToMenu()}
        else {vrView?.isPaused = !inVR;startBrowserCapture()}
    }

    private func updateCalibrationHand(_ sample: HandSample?) {
        guard let calibration=lensCalibrationView else {return}
        guard let sample,let frame=tracking.latestFrameCopy,!sample.isFist else {calibration.cancelInteraction();return}
        let oriented=sample.indexTip.applying(frame.displayTransform(for:currentInterfaceOrientation(),viewportSize:view.bounds.size))
        calibration.updatePointer(CGPoint(x:oriented.x*view.bounds.width*0.5,y:oriented.y*view.bounds.height),
            down:sample.clickPinch,allowBegin:sample.clickBegan,dwell:usesDwell,time:CACurrentMediaTime())
    }

    private func enterVR() {
        guard !inVR else { return }
        handOwnership.reset()
        hands.reset()
        inVR = true
        handClickMode = HandClickMode.load()
        pointerControlMode = PointerControlMode.load()
        headAimSession.reset()
        headNode.simdTransform=matrix_identity_float4x4
        didCreateInitialAnchor = false
        browserAnchor = nil
        browserWorldTransform = nil
        isDragging = false
        isResizing = false
        resizeStartHandDistance = 0
        controllerPointer = CGPoint(x: 0.5, y: 0.5)
        controllerButtonDown = false
        controllerPointer = CGPoint(x: 0.5, y: 0.5)
        controllerHandRoot.isHidden = true
        resetPanelToDefaultSizeInstantly()
        hideDirectVideoStage()
        activateMediaAudioSession()

        applyEyeGeometry()
        requestLandscapeMode()
        setVRVisible(true)

        tracking.setInterfaceOrientation(currentInterfaceOrientation())
        tracking.start()

        UIApplication.shared.isIdleTimerDisabled = true
        startBrowserCapture()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Каждый заход в VR начинается с обычного размера панели, без анимации —
    /// панель в этот момент ещё скрыта, доигрывать переход не для кого.
    private func resetPanelToDefaultSizeInstantly() {
        isCinemaMode = false
        browserWorldWidth = SpatialWindowSizing.restoredWidth(defaults: .standard, fallback: Self.defaultPanelWidth)
        browserWorldHeight = browserWorldWidth * Self.defaultPanelAspect

        updatePanelSize(width: browserWorldWidth)
        toolbarNode.opacity = 1
        toolbarNode.isHidden = !browser.isOpaque
    }

    private func setVRVisible(_ visible: Bool) {
        vrView?.isHidden = !visible
        vrView?.isPaused = !visible
        menu?.isHidden = visible
        menu?.isUserInteractionEnabled = !visible
        browserPlaneNode.isHidden = true
        hidePointer()
        leftHandSkeletonNode.isHidden = true
        rightHandSkeletonNode.isHidden = true
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    /// Запуск VR-игры: скрываем браузерную панель и разворачиваем сцену клуба.
    /// Доступна из раздела «Игры» VR Desktop (уже внутри VR) и может быть
    /// вызвана повторно без выхода из VR.
    private func startSecurityVR() {
        cancelHandInteraction()
        handOwnership.suppressUntilOpen()
        if !inVR {
            inVR = true
            handClickMode = HandClickMode.load()
            pointerControlMode = PointerControlMode.load()
            headAimSession.reset()
            headNode.simdTransform=matrix_identity_float4x4
            applyEyeGeometry()
            requestLandscapeMode()
            setVRVisible(true)
            tracking.setInterfaceOrientation(currentInterfaceOrientation())
            tracking.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        securityGameActive = true

        // Убираем браузерный слой и пасстр-указатель: игра живёт в той же сцене.
        stopBrowserCapture()
        hideDirectVideoStage()
        browserPlaneNode.isHidden = true
        toolbarNode.isHidden = true
        hidePointer()
        hidePointerDot()
        releasePointer()

        let forward = simd_normalize(SIMD3<Float>(
            -headNode.simdWorldTransform.columns.2.x,
            0,
            -headNode.simdWorldTransform.columns.2.z
        ))
        securityGame.onInteraction = { [weak self] in self?.playUIConfirmation() }
        securityGame.onExitRequested = { [weak self] in
            self?.exitSecurityVR()
        }
        securityGame.start(
            in: worldScene,
            cameraOrigin: headNode.simdWorldPosition,
            cameraForward: forward
        )

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func exitSecurityVR() {
        securityGame.stop()
        securityGameActive = false
        // Возврат в VR Desktop: игра открывалась из раздела «Игры».
        toolbarNode.isHidden = false
        browserPlaneNode.isHidden = false
        openVRDesktop()
        startBrowserCapture()
        hidePointer()
        hidePointerDot()
    }

    // MARK: Time Motion

    private func startTimeMotionVR() {
        guard inVR, !cinemaActive, !graffitiActive, !panoramaActive, !securityGameActive else { return }
        guard !usesHeadAim else {
            showAlert("Для Time Motion включи управление рукой в настройках. Кнопки игры работают удержанием указателя.")
            return
        }
        activateMediaAudioSession()
        cancelHandInteraction(); endDrag(); endResize(); hands.reset(); handOwnership.reset(); menuSwipe.reset()
        queueHandForegroundMask(left: nil, right: nil)
        securityGameActive = true; timeMotionActive = true; timeMotionAligned = false
        timeMotionLeft = nil; timeMotionRight = nil
        spatialHomeVisible = false
        stopBrowserCapture(); browser.stopLoading(); pauseAndMute(browser); hideDirectVideoStage()
        browserPlaneNode.isHidden = true; toolbarNode.isHidden = true
        hidePointer(); hidePointerDot(); releasePointer(); controllerHandRoot.isHidden = true
        virtualHands.start(in: worldScene)
        timeMotion.onExitRequested = { [weak self] in self?.exitTimeMotionVR() }
        let axis = headNode.simdWorldTransform.columns.2
        timeMotion.start(in: worldScene, headPosition: headNode.simdWorldPosition, forward: SIMD3(-axis.x,0,-axis.z))
        timeMotion.showLoading()
        timeMotionCameraOverridden = (tracking.latestFrameCopy?.mode ?? CameraMode.load(ultraWideAvailable: UltraWideCapture.isAvailable)) != .worldTracking
        if timeMotionCameraOverridden { tracking.start(mode: .worldTracking) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func exitTimeMotionVR() {
        guard timeMotionActive else { return }
        timeMotion.stop(); virtualHands.stop()
        timeMotionActive = false; securityGameActive = false; timeMotionAligned = false
        timeMotionLeft = nil; timeMotionRight = nil
        if timeMotionCameraOverridden { tracking.start() }
        timeMotionCameraOverridden = false
        cancelHandInteraction(); hands.reset(); handOwnership.reset()
        queueHandForegroundMask(left: nil, right: nil)
        resetBrowserAnchor(); openVRDesktop(); startBrowserCapture()
        hidePointer(); hidePointerDot()
    }

    private func timeMotionInput(_ sample: HandSample?, now: Double) -> TimeMotionHandInput? {
        guard let sample, VirtualHandPose.fresh(sample.timestamp, at: now) else { return nil }
        let pose = virtualHandPose(sample, distance: graffitiHandDistance(sample))
        var aim: WorldRay?
        if let wrist = sample.maskJoints[.wrist], let base = sample.maskJoints[.middleMCP] {
            let palm = CGPoint(x: (wrist.x + base.x) * 0.5, y: (wrist.y + base.y) * 0.5)
            aim = tracking.worldRay(visionPoint: palm)
        }
        return TimeMotionHandInput(hand: sample.hand, timestamp: sample.timestamp, pose: pose,
                                   aimRay: aim, trackingGeneration: sample.trackingGeneration,
                                   fist: sample.isFist, open: sample.openPalmCenter != nil,
                                   pinch: sample.clickPinch)
    }

    /// Runs once per rendered frame, so the game clock does not depend on hand delivery.
    private func tickTimeMotion(at now: Double) {
        guard timeMotionActive, inVR else { return }
        let ready = graffitiTrackingReady && timeMotionHeadMode == .worldTracking
        if !timeMotionAligned {
            guard ready else { return }
            let axis = headNode.simdWorldTransform.columns.2
            let flat = SIMD3<Float>(-axis.x,0,-axis.z)
            let direction = simd_length(flat) > 0.1 ? simd_normalize(flat) : SIMD3<Float>(0,0,-1)
            timeMotion.stop()
            timeMotion.start(in: worldScene, headPosition: headNode.simdWorldPosition, forward: direction)
            timeMotionAligned = true
        }
        let left = timeMotionInput(timeMotionLeft, now: now)
        let right = timeMotionInput(timeMotionRight, now: now)
        timeMotion.update(now: now, left: left, right: right, headTransform: headNode.simdWorldTransform,
                          trackingReady: ready, dwell: true, headTimestamp: timeMotionHeadTimestamp)
        guard timeMotionActive else { return }
        controllerHandRoot.isHidden = true
        virtualHands.tick(at: now, ready: ready, head: headNode)
        virtualHands.update(hand: .left, pose: left?.pose, timestamp: left?.timestamp ?? -.infinity,
                            at: now, visible: false)
        virtualHands.update(hand: .right, pose: right?.pose, timestamp: right?.timestamp ?? -.infinity,
                            at: now, visible: false)
    }

    // MARK: Graffiti

    private func startGraffiti() {
        guard inVR, !cinemaActive, !securityGameActive else { return }
        activateMediaAudioSession()
        cancelHandInteraction(); endDrag(); endResize(); hands.reset(); handOwnership.reset(); menuSwipe.reset()
        queueHandForegroundMask(left: nil, right: nil)
        stopBrowserCapture(); browser.stopLoading(); pauseAndMute(browser); hideDirectVideoStage()
        browserPlaneNode.isHidden = true; toolbarNode.isHidden = true
        spatialHomeVisible = false
        hidePointer(); hidePointerDot(); controllerHandRoot.isHidden = true
        graffiti.onImportMusic = { [weak self] in self?.importGraffitiMusic() }
        graffiti.onExit = { [weak self] in self?.exitGraffiti() }
        graffiti.onModeChanged = { [weak self] mode in self?.tracking.setWallDetectionEnabled(mode == .home) }
        graffiti.onAddAnchor = { [weak self] anchor in self?.tracking.add(anchor: anchor) }
        graffiti.onRemoveAnchor = { [weak self] anchor in self?.tracking.remove(anchor: anchor) }
        graffiti.wallHit = { [weak self] ray in self?.tracking.detectedWallHit(ray: ray) }
        graffiti.start(in: worldScene, head: headNode)
        virtualHands.start(in: worldScene)
        graffitiCameraOverridden = (tracking.latestFrameCopy?.mode ?? CameraMode.load(ultraWideAvailable: UltraWideCapture.isAvailable)) != .worldTracking
        if graffitiCameraOverridden {
            tracking.start(mode: .worldTracking)
        } else if graffitiTrackingReady { graffiti.align(head: headNode) }
    }

    private func stopGraffiti(restoreCamera: Bool) {
        guard graffitiActive else { return }
        queueHandForegroundMask(left: nil, right: nil)
        graffiti.stop(); virtualHands.stop(); tracking.setWallDetectionEnabled(false)
        if restoreCamera, graffitiCameraOverridden { tracking.start() }
        graffitiCameraOverridden = false
        cancelHandInteraction(); hands.reset(); handOwnership.reset()
    }

    private func exitGraffiti() {
        stopGraffiti(restoreCamera: true)
        resetBrowserAnchor(); openVRDesktop()
        hidePointer(); hidePointerDot()
    }

    private func importGraffitiMusic() {
        guard graffitiActive, presentedViewController == nil else { return }
        graffiti.cancelInput()
        let picker = GraffitiMusicPicker { [weak self] urls in
            guard let self else { return }
            self.graffitiMusicPicker = nil
            if self.graffitiActive, !urls.isEmpty { self.graffiti.importMusic(urls) }
        }
        graffitiMusicPicker = picker
        picker.present(from: self)
    }

    private func handleGraffitiHands(left: HandSample?, right: HandSample?, at time: Double) {
        let candidates = [right, left].compactMap { $0 }
        let sample = candidates.first { $0.hand == graffiti.handOwner } ?? candidates.first
        let ready = graffitiTrackingReady
        let palm: CGPoint? = sample.flatMap { sample in
            guard let wrist = sample.maskJoints[.wrist], let base = sample.maskJoints[.middleMCP] else { return nil }
            return CGPoint(x: (wrist.x + base.x) * 0.5, y: (wrist.y + base.y) * 0.5)
        }
        let ray = ready ? palm.flatMap { tracking.worldRay(visionPoint: $0) } : nil
        let blocked = usesHeadAim ? false : graffiti.updateUI(ray: ray, hand: sample?.hand, at: time)
        // Feed both hands before painting: selecting/holding a prop consumes
        // that hand, and an opening used to drop it must not spray the wall.
        for hand in [TrackedHand.left, .right] {
            let candidate = hand == .left ? left : right
            let tracked = candidate.flatMap { VirtualHandPose.fresh($0.timestamp, at: time) ? $0 : nil }
            let center = tracked.flatMap { tracked -> CGPoint? in
                guard let w = tracked.maskJoints[.wrist], let m = tracked.maskJoints[.middleMCP] else { return nil }
                return CGPoint(x: (w.x+m.x)*0.5, y: (w.y+m.y)*0.5)
            }
            let propRay = ready ? center.flatMap { tracking.worldRay(visionPoint: $0) } : nil
            graffiti.updateProp(hand: hand, generation: tracked?.trackingGeneration, fist: tracked?.isFist == true,
                open: tracked?.openPalmCenter != nil, ray: propRay, distance: graffitiHandDistance(tracked),
                orientation: headNode.simdWorldOrientation, blocked: blocked, trackingReady: ready, at: time)
        }
        let distance = graffitiHandDistance(sample)
        let head = headNode.simdWorldTransform
        let rightAxis = SIMD3(head.columns.0.x, head.columns.0.y, head.columns.0.z)
        let upAxis = SIMD3(head.columns.1.x, head.columns.1.y, head.columns.1.z)
        let offset = VirtualHandPose.canOffset(distance: distance, left: sample?.hand == .left, right: rightAxis, up: upAxis)
        graffiti.updateHand(hand: sample?.hand, open: sample?.openPalmCenter != nil,
                            ray: ray, distance: distance, toolOffset: offset, blocked: blocked, trackingReady: ready, at: time)
        for hand in [TrackedHand.left, .right] {
            let tracked = hand == .left ? left : right
            let visible = ready && graffitiActive && graffiti.showsVirtualHand(hand)
            let pose = visible ? tracked.flatMap { virtualHandPose($0, distance: graffitiHandDistance($0)) } : nil
            virtualHands.update(hand: hand, pose: pose, timestamp: tracked?.timestamp ?? -.infinity, at: time, visible: visible)
        }
        if !usesHeadAim {
            if let ray { showPointerDot(at: ray.point(at: 0.9), transform: headNode.simdWorldTransform, active: false) }
            else { hidePointerDot() }
            rayNode.isHidden = true
        }
        controllerHandRoot.isHidden = true
    }

    private func graffitiHandDistance(_ sample: HandSample?) -> Float {
        if let sample, let wrist = sample.maskJoints[.wrist], let base = sample.maskJoints[.middleMCP],
           let frame = tracking.latestFrameCopy, let projection = tracking.projection(for: frame) {
            let aspect = Double(frame.camera.imageResolution.width) / Double(frame.camera.imageResolution.height)
            let dx = Double(wrist.x - base.x)*aspect, dy = Double(wrist.y - base.y)
            return GraffitiGeometry.canDistance(palmFraction: sqrt(dx * dx + dy * dy),
                verticalTangent: Double(frame.camera.imageResolution.height) / (2 * projection.fy))
        }
        return 0.5
    }

    private func virtualHandPose(_ sample: HandSample, distance: Float) -> VirtualHandPose? {
        guard let wrist = sample.maskJoints[.wrist], let base = sample.maskJoints[.middleMCP] else { return nil }
        let center = CGPoint(x: (wrist.x+base.x)*0.5, y: (wrist.y+base.y)*0.5)
        guard let palmRay = tracking.worldRay(visionPoint: center) else { return nil }
        let names: [VNHumanHandPoseObservation.JointName] = [
            .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip]
        let points = names.map { name -> SIMD3<Float>? in
            guard let point = sample.maskJoints[name], point.x.isFinite, point.y.isFinite,
                  (0...1).contains(point.x), (0...1).contains(point.y),
                  let ray = tracking.worldRay(visionPoint: point) else { return nil }
            let alignment = simd_dot(ray.direction, palmRay.direction)
            guard alignment > 0.5 else { return nil }
            return ray.point(at: distance/alignment)
        }
        return VirtualHandPose(points: points, camera: palmRay.origin)
    }

    // MARK: Offline 360° travel

    private func startPanorama(id: String) {
        guard inVR, !cinemaActive, !securityGameActive,
              let asset = OfflinePanoramaAsset.load(id: id) else {
            showAlert("Не найден файл панорамы. Проверь ресурсы сборки.")
            return
        }
        cancelHandInteraction(); endDrag(); endResize()
        handOwnership.suppressUntilOpen(); menuSwipe.reset()
        stopBrowserCapture(); browser.stopLoading(); pauseAndMute(browser)
        hideDirectVideoStage()
        spatialHomeVisible = false
        browserPlaneNode.isHidden = true; toolbarNode.isHidden = true
        hidePointer(); hidePointerDot(); controllerHandRoot.isHidden = true
        panorama.onInteraction = { [weak self] in self?.playUIConfirmation() }
        panorama.onExit = { [weak self] in self?.exitPanorama() }
        panorama.onRecenter = { [weak self] in
            guard let self else { return }
            self.panorama.recenter(head: self.headNode)
        }
        panorama.start(asset: asset, scene: worldScene, head: headNode)
    }

    private func exitPanorama() {
        cancelHandInteraction()
        panorama.stop()
        handOwnership.suppressUntilOpen()
        resetBrowserAnchor()
        openVRApp(id: "travel")
        startBrowserCapture()
        hidePointer(); hidePointerDot()
    }

    private func handlePanoramaRay(_ ray: WorldRay?, down: Bool, allowBegin: Bool, dwell: Bool) {
        panorama.update(ray: ray, pinch: down, allowBegin: allowBegin, dwell: dwell)
        if panoramaActive, let ray {
            showPointerDot(at: ray.point(at: 0.9), transform: headNode.simdWorldTransform, active: down)
            rayNode.isHidden = true
        } else { hidePointerDot() }
    }

    private func updatePanoramaController() {
        let frustum = VRLensMath.frustum(eye: 0, profile: profile)
        let x = frustum.left + Float(controllerPointer.x) * (frustum.right - frustum.left)
        let y = frustum.top - Float(controllerPointer.y) * (frustum.top - frustum.bottom)
        let t = headNode.simdWorldTransform
        let d = t * SIMD4<Float>(x, y, -1, 0)
        let ray = WorldRay(origin: headNode.simdWorldPosition, direction: simd_normalize(SIMD3(d.x, d.y, d.z)))
        controllerHandRoot.isHidden = true
        handlePanoramaRay(ray, down: controllerButtonDown, allowBegin: true, dwell: false)
    }

    // MARK: Кинотеатр

    /// Вход в 3D-кинозал. Браузерная панель становится экраном, вокруг неё
    /// строится зал с креслами, правым пультом и быстрыми действиями.
    private func enterCinema(url: URL?) {
        cancelHandInteraction()
        handOwnership.suppressUntilOpen()
        applySpatialSurface(home: false, transparent: false)
        stopCinemaProbe()
        cinemaPlayback.release()
        if !inVR {
            inVR = true
            handClickMode = HandClickMode.load()
            pointerControlMode = PointerControlMode.load()
            headAimSession.reset()
            headNode.simdTransform=matrix_identity_float4x4
            didCreateInitialAnchor = false
            browserAnchor = nil
            browserWorldTransform = nil
            applyEyeGeometry()
            requestLandscapeMode()
            setVRVisible(true)
            tracking.setInterfaceOrientation(currentInterfaceOrientation())
            tracking.start()
            UIApplication.shared.isIdleTimerDisabled = true
            activateMediaAudioSession()
        }
        cinemaActive = true
        cinemaNeedsAlignment = true
        if let frame=tracking.latestFrameCopy, tracking.isCurrent(frame),
           CACurrentMediaTime()-frame.timestamp < 0.25 {
            headNode.simdTransform=tracking.headTransform(frame)
            cinemaNeedsAlignment = false
        }

        stopBrowserCapture()
        hideDirectVideoStage()
        releasePointer()
        hidePointer()
        hidePointerDot()
        toolbarNode.isHidden = true
        browserHandleNode.isHidden = true

        let forward = SIMD3<Float>(
            -headNode.simdWorldTransform.columns.2.x,
            0,
            -headNode.simdWorldTransform.columns.2.z
        )

        cinemaHall.onInteraction = { [weak self] in self?.playUIConfirmation() }
        cinemaHall.onExitRequested = { [weak self] in self?.exitCinema() }
        cinemaHall.onPlayPause = { [weak self] in self?.cinemaTogglePlay() }
        cinemaHall.onVolume = { [weak self] delta in self?.cinemaVolume(delta) }
        cinemaHall.onSeek = { [weak self] delta in self?.cinemaSeek(by: delta) }
        cinemaHall.onRestart = { [weak self] in self?.cinemaRestart() }
        cinemaHall.onRemoteRequested = { [weak self] in self?.toggleCinemaRemote() }
        cinemaHall.onPeekRequested = { [weak self] in self?.toggleCinemaPeek() }
        cinemaHall.onRealignRequested = { [weak self] in self?.alignCinemaToCurrentPose() }
        cinemaPlayback.onProgress = { [weak self] current, duration in
            self?.cinemaHall.setTime(current: current, duration: duration)
            if let self {
                self.cinemaHall.setPlayingState(self.cinemaPlayback.isPlaying)
                self.cinemaHall.setSoundEnabled(self.cinemaPlayback.isSoundEnabled)
            }
        }
        cinemaPlayback.onStarted = { [weak self] in
            self?.cinemaHall.setNotice("")
        }
        cinemaPlayback.onFailed = { [weak self] message in
            guard let self else { return }
            NSLog("HandAR cinema playback failed: %@", message)
            guard self.cinemaActive else { return }
            self.cinemaHall.setPlayingState(false)
            if let original = self.cinemaOriginalURL, !self.isDirectMediaURL(original) {
                self.startCinemaWebFallback()
            } else {
                self.cinemaHall.setNotice("Ошибка загрузки видео: " + message)
            }
        }
        cinemaHall.start(in: worldScene, cameraOrigin: headNode.simdWorldPosition, cameraForward: forward)
        cinemaHall.attachComfortControls(to: headNode)
        cinemaHall.setHeadAiming(usesHeadAim, head: headNode)

        // Браузерная панель становится экраном зала.
        browserWorldWidth = CinemaHall.screenWidth
        browserWorldHeight = CinemaHall.screenHeight
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        browserPlaneGeometry.width = CGFloat(browserWorldWidth)
        browserPlaneGeometry.height = CGFloat(browserWorldHeight)
        browserFrameGeometry.width = CGFloat(browserWorldWidth) + 0.018
        browserFrameGeometry.height = CGFloat(browserWorldHeight) + 0.018
        SCNTransaction.commit()
        browserPlaneNode.simdWorldTransform = cinemaHall.screenWorldTransform
        browserPlaneNode.isHidden = false

        // Звук кинотеатра не должен зависеть от положения беззвучного тумблера.
        activateMediaAudioSession()

        let requested = url ?? Self.youTubeURL
        cinemaOriginalURL = youtubeWatchURL(requested) ?? requested
        if isYouTubePage(requested) {
            // Do not wait for an extractable URL from YouTube's HTML video.
            startCinemaWebFallback()
            return
        }
        let target = requested
        if isDirectMediaURL(target) {
            // Прямой файл — сразу нативный плеер, никакой обвязки сайта.
            cinemaSourceURL = nil
            cinemaHall.setNotice("загружаю видео…")
            cinemaPlayback.load(url: target, into: browserMaterial)
            cinemaHall.setPlayingState(true)
        } else {
            // Страница (YouTube и прочие): загружаем, забираем у её <video>
            // прямую ссылку на поток и переключаем экран на AVPlayer.
            cinemaSourceURL = target
            cinemaHall.setNotice("открываю видео…")
            browser.load(URLRequest(url: target))
            startBrowserCapture()
            startCinemaProbe()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Кино: пробник источника

    private func startCinemaWebFallback() {
        guard cinemaActive, let original = cinemaOriginalURL else { return }
        stopCinemaProbe()
        cinemaPlayback.release()
        pauseAndMuteBrowserMedia()
        // Keep the site's real video layer visible; WK snapshots cannot carry it.
        cinemaHall.setNotice("")
        presentDirectVideoStage(url: original)
    }

    private func startCinemaProbe() {
        cinemaProbeTimer?.invalidate()
        cinemaProbeGeneration = UUID()
        let generation = cinemaProbeGeneration
        var attempts = 0
        cinemaProbeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.cinemaActive else { self.stopCinemaProbe(); return }
            attempts += 1
            guard attempts < 16 else {
                // Поток так и не отдан. Экран уже рисует снимки страницы,
                // но на случай, если и они чёрные — честная подпись.
                self.startCinemaWebFallback()
                return
            }
            guard !self.cinemaPlayback.isActive else {
                self.stopCinemaProbe()
                return
            }
            self.browser.evaluateJavaScript(
                "window.__handarVideoInfo ? window.__handarVideoInfo() : 'null';"
            ) { [weak self] raw, _ in
                guard let self, self.cinemaActive, self.cinemaProbeGeneration == generation, !self.cinemaPlayback.isActive,
                      let raw = raw as? String, raw != "null",
                      let data = raw.data(using: .utf8),
                      let info = try? JSONSerialization.jsonObject(with: data),
                      let object = info as? [String: Any],
                      object["ok"] as? Bool == true
                else { return }

                if let source = object["src"] as? String, source.hasPrefix("blob:") {
                    self.startCinemaWebFallback()
                    return
                }
                if object["usable"] as? Bool == true,
                   let src = object["src"] as? String,
                   let videoURL = URL(string: src) {
                    self.stopCinemaProbe()
                    self.cinemaUsePlayer(videoURL)
                } else {
                    // Пока поток не отдан — растягиваем видео на всю панель,
                    // чтобы снимок (fallback) не был в рамке сайта.
                    self.browser.evaluateJavaScript(
                        "window.__handarCinemaCommand && window.__handarCinemaCommand('fill');",
                        completionHandler: nil
                    )
                    // Пытаемся запустить воспроизведение: автозапуск на
                    // страницах иногда ждёт действия.
                    self.browser.evaluateJavaScript(
                        "window.__handarCinemaCommand && window.__handarCinemaCommand('play');",
                        completionHandler: nil
                    )
                }
            }
        }
    }

    private func stopCinemaProbe() {
        cinemaProbeGeneration = UUID()
        cinemaProbeTimer?.invalidate()
        cinemaProbeTimer = nil
    }

    /// Переключает экран зала на нативный плеер и глушит страницу.
    private func cinemaUsePlayer(_ url: URL) {
        browser.evaluateJavaScript(
            "window.__handarCinemaCommand && window.__handarCinemaCommand('mute');",
            completionHandler: nil
        )
        cinemaPlayback.load(url: url, into: browserMaterial)
        cinemaHall.setPlayingState(true)
        cinemaHall.setNotice("")
        stopBrowserCapture()
    }

    private func exitCinema() {
        cinemaNeedsAlignment = false
        stopCinemaProbe()
        cinemaPlayback.release()
        cinemaHall.stop()
        cinemaActive = false
        isCinemaMode = false
        cinemaSourceURL = nil
        cinemaOriginalURL = nil
        cinemaHall.setNotice("")
        browserHandleNode.isHidden = false
        toolbarNode.isHidden = false
        hideDirectVideoStage()
        resetPanelToDefaultSizeInstantly()
        openVRDesktop()
        startBrowserCapture()
        hidePointer()
        hidePointerDot()
    }

    private func cinemaTogglePlay() {
        activateDirectVideoAudio()
        if cinemaPlayback.isActive {
            cinemaPlayback.toggle()
            cinemaHall.setPlayingState(cinemaPlayback.isPlaying)
        } else {
            toggleCinemaPlayPause()
        }
    }

    private func alignCinemaToCurrentPose() {
        guard cinemaActive, cinemaHall.isRunning else { return }
        cinemaNeedsAlignment = false
        let transform=headNode.simdWorldTransform
        cinemaHall.restoreRemote()
        let forward = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
        if cinemaHall.comfort.isReclined {
            cinemaHall.alignReclinedViewer(origin: headNode.simdWorldPosition, forward: forward)
        } else {
            cinemaHall.alignViewer(origin: headNode.simdWorldPosition, forward: forward)
        }
        cinemaHall.setHeadAiming(usesHeadAim, head: headNode)
        browserPlaneNode.simdWorldTransform=cinemaHall.screenWorldTransform
        updateCinemaWebScreen()
        cancelHandInteraction()
    }

    private func toggleCinemaRemote() {
        guard cinemaActive, !cinemaHall.comfort.isPeeking else { return }
        cancelHandInteraction()
        controllerButtonDown = false
        cinemaHall.toggleRemote(headTransform: headNode.simdWorldTransform, at: CACurrentMediaTime())
    }

    private func toggleCinemaPeek() {
        guard cinemaActive else { return }
        let peeking = !cinemaHall.comfort.isPeeking
        if peeking {
            guard let frame = tracking.latestFrameCopy, tracking.isCurrent(frame),
                  CACurrentMediaTime() - frame.timestamp < 0.25 else {
                cinemaHall.setNotice("Камера пока недоступна")
                return
            }
        }
        setCinemaPeeking(peeking)
    }

    private func setCinemaPeeking(_ peeking: Bool) {
        cancelHandInteraction()
        controllerButtonDown = false
        hidePointer()
        controllerHandRoot.isHidden = true
        cinemaHall.setPeeking(peeking)
        browserPlaneNode.isHidden = peeking
        // Hide only the presentation. Keep the single player/page alive; do not
        // reload, mute, or send play when returning from the camera.
        liveWebReplicator.alpha = peeking ? 0 : 1
        updateCinemaWebPointers(nil)
    }

    private func updateCinemaControlOcclusion() {
        guard cinemaWebScreenActive, !cinemaHall.comfort.isPeeking else {
            liveWebReplicator.layer.mask = nil
            return
        }
        let bounds = liveWebReplicator.bounds
        let half = Double(bounds.width / 2)
        let shift = SIMD2<Double>(Double(liveWebReplicator.copyOffset.x), Double(liveWebReplicator.copyOffset.y))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var previous: CALayer?
        liveWebReplicator.layer.mask = nil
        for (index, panel) in cinemaHall.overlayPanels.enumerated() {
            guard cinemaControlMasks.indices.contains(index) else { break }
            let w = panel.width / 2, h = panel.height / 2
            let corners = [SIMD3<Float>(-w, h, 0.045), SIMD3<Float>(w, h, 0.045),
                           SIMD3<Float>(w, -h, 0.045), SIMD3<Float>(-w, -h, 0.045)]
            let left = corners.compactMap { projectedCinemaCorner($0, eye: 0, using: panel.transform) }
            guard left.count == 4 else { continue }
            let path = UIBezierPath(rect: bounds)
            for eye in 0..<2 {
                let polygon = eye == 0 ? left : left.map { $0 + shift }
                let clipped = CinemaControlMask.clipped(polygon, minX: Double(eye) * half,
                    maxX: Double(eye + 1) * half, maxY: Double(bounds.height))
                guard let first = clipped.first else { continue }
                path.move(to: CGPoint(x: first.x, y: first.y))
                for point in clipped.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                path.close()
            }
            let mask = cinemaControlMasks[index]
            mask.mask = nil
            mask.frame = bounds
            mask.fillColor = UIColor.white.cgColor
            mask.fillRule = .evenOdd
            mask.path = path.cgPath
            // Multiply independent masks. Overlapping holes must stay clear,
            // unlike one even-odd path which would reveal video at intersections.
            if let previous { previous.mask = mask } else { liveWebReplicator.layer.mask = mask }
            previous = mask
        }
    }

    private func tickCinemaComfort(at time: Double) {
        guard cinemaActive else { return }
        let frame = tracking.latestFrameCopy
        let fresh = frame.map { tracking.isCurrent($0) && time >= $0.timestamp && time - $0.timestamp < 0.5 } ?? false
        if !fresh, cinemaHall.comfort.reclineDeadline != nil {
            cinemaHall.cancelPendingRecline()
            cinemaHall.setNotice("Камера недоступна — настройка наклона отменена")
        }
        cinemaHall.tick(at: time)
        if cinemaHall.comfort.isPeeking {
            if !fresh {
                setCinemaPeeking(false)
                cinemaHall.setNotice("Камера недоступна — возврат в зал")
            }
        }
        browserPlaneNode.isHidden = cinemaHall.comfort.isPeeking
        liveWebReplicator.alpha = cinemaHall.comfort.isPeeking ? 0 : 1
    }

    /// Both a tracked hand and the controller use the same spatial controls.
    private func handleCinemaRay(_ ray: WorldRay?, down: Bool, allowBegin: Bool, dwell: Bool) {
        guard cinemaActive else { return }
        let consumed = cinemaHall.update(ray: ray, pinch: down, allowBegin: allowBegin, dwell: dwell)
        guard !consumed, !cinemaHall.comfort.isPeeking, let ray,
              let hit = planeHit(ray: ray, transform: cinemaHall.screenWorldTransform) else {
            releasePointer()
            hidePointer()
            return
        }
        let uv = CGPoint(x: CGFloat(hit.localX / CinemaHall.screenWidth + 0.5),
                         y: CGFloat(0.5 - hit.localY / CinemaHall.screenHeight))
        guard (0...1).contains(uv.x), (0...1).contains(uv.y) else {
            releasePointer(); hidePointer(); return
        }
        if cinemaWebScreenActive {
            updateDirectVideoInput(normalizedPoint: uv, pinch: down, allowBegin: allowBegin, dwell: dwell)
        } else if !cinemaPlayback.isActive {
            input.update(normalizedPoint: uv, pinch: down, webView: browser, allowBegin: allowBegin, dwell: dwell)
        }
    }

    private func updateCinemaController() {
        let frustum = VRLensMath.frustum(eye: 0, profile: profile)
        let x = frustum.left + Float(controllerPointer.x) * (frustum.right - frustum.left)
        let y = frustum.top - Float(controllerPointer.y) * (frustum.top - frustum.bottom)
        let transform = headNode.simdWorldTransform
        let direction = transform * SIMD4<Float>(x, y, -1, 0)
        let ray = WorldRay(origin: headNode.simdWorldPosition,
                           direction: simd_normalize(SIMD3(direction.x, direction.y, direction.z)))
        controllerHandRoot.isHidden = true
        handleCinemaRay(ray, down: controllerButtonDown, allowBegin: true, dwell: false)
        if cinemaActive {
            showPointerDot(at: ray.point(at: 0.9), transform: transform, active: controllerButtonDown)
        }
    }

    private func cinemaVolume(_ delta: Float) {
        guard cinemaPlayback.isActive else { adjustCinemaVolume(delta); return }
        activateDirectVideoAudio()
        cinemaPlayback.volume += delta
        cinemaHall.setSoundEnabled(cinemaPlayback.isSoundEnabled)
    }

    private func cinemaSeek(by seconds: Double) {
        if cinemaWebScreenActive {
            directVideoLeft.evaluateJavaScript("window.__handarSeekVideo && window.__handarSeekVideo(\(seconds), false);") { [weak self] _, _ in self?.syncDirectVideoEyes() }
            return
        }
        guard cinemaPlayback.isActive else { return }
        cinemaPlayback.seek(by: seconds)
    }

    private func cinemaRestart() {
        if cinemaWebScreenActive, cinemaWebRecoveryRequired { retryCinemaWebVideo(); return }
        activateDirectVideoAudio()
        if cinemaWebScreenActive {
            directVideoLeft.evaluateJavaScript("window.__handarSeekVideo && window.__handarSeekVideo(0, true);") { [weak self] _, _ in self?.syncDirectVideoEyes() }
            return
        }
        guard cinemaPlayback.isActive else { return }
        cinemaPlayback.restart()
        cinemaHall.setPlayingState(true)
    }

    private func toggleCinemaPlayPause() {
        let js = "window.__handarTogglePlay ? window.__handarTogglePlay() : null;"
        if directVideoActive {
            directVideoLeft?.evaluateJavaScript(js) { [weak self] result, _ in
                if let state = result as? String {
                    self?.cinemaHall.setPlayingState(state != "pause")
                }
                self?.syncDirectVideoEyes()
            }
        } else {
            browser.evaluateJavaScript(js) { [weak self] result, _ in
                if let state = result as? String {
                    self?.cinemaHall.setPlayingState(state != "pause")
                }
            }
        }
    }

    private func adjustCinemaVolume(_ delta: Float) {
        activateDirectVideoAudio()
        let js = "window.__handarSetVolume ? window.__handarSetVolume(\(delta)) : null;"
        if directVideoActive {
            directVideoLeft?.evaluateJavaScript(js, completionHandler: nil)
        } else {
            browser.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func cinemaURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed : "https://" + trimmed
        return URL(string: value)
    }

    private func leaveVRToMenu() {
        lensCalibrationView?.cancelInteraction()
        lensCalibrationView?.removeFromSuperview()
        lensCalibrationView=nil
        returnToMenuAfterCalibration=false
        cancelHandInteraction()
        handOwnership.reset()
        hands.reset()
        stopGraffiti(restoreCamera: false)
        tracking.pause()
        panorama.stop()
        stopBrowserCapture()
        hideDirectVideoStage()
        releasePointer()
        stopCinemaProbe()
        cinemaPlayback.release()
        cinemaSourceURL = nil
        cinemaOriginalURL = nil
        cinemaHall.setNotice("")

        if securityGameActive {
            securityGame.stop()
            securityGameActive = false
        }

        if timeMotionActive {
            timeMotion.stop()
            virtualHands.stop()
            timeMotionActive = false; timeMotionAligned = false; timeMotionCameraOverridden = false
            timeMotionLeft = nil
            timeMotionRight = nil
        }

        if cinemaActive {
            cinemaHall.stop()
            cinemaActive = false
        }

        if let anchor = browserAnchor {
            tracking.remove(anchor: anchor)
        }

        browserAnchor = nil
        browserWorldTransform = nil
        didCreateInitialAnchor = false
        isDragging = false
        isResizing = false
        inVR = false

        UIApplication.shared.isIdleTimerDisabled = false
        deactivateMediaAudioSession()
        setVRVisible(false)
        controllerHandRoot.isHidden = true
        requestLandscapeMode()
    }

    @objc private func handleRecenterTap() {
        // В кинотеатре тап по экрану не должен перетягивать экран зала.
        guard inVR, !cinemaActive else { return }
        if timeMotionActive { timeMotion.recenterControls(head: headNode); return }
        if graffitiActive { graffiti.recenterControls(head: headNode); return }
        if panoramaActive { panorama.recenter(head: headNode); return }
        resetBrowserAnchor()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func handleExitTap() {
        guard inVR else { return }
        leaveVRToMenu()
    }

    private func showVRBoxDiagnostics() {
        guard diagnosticsView == nil else { return }
        let diagnostics = VRBoxDiagnosticsView()
        diagnostics.onClose = { [weak self, weak diagnostics] in
            guard let diagnostics else { return }
            diagnostics.willMove(toParent: nil)
            diagnostics.view.removeFromSuperview()
            diagnostics.removeFromParent()
            self?.diagnosticsView = nil
            self?.menu?.isHidden = false
            self?.menu?.isUserInteractionEnabled = true
        }
        diagnosticsView = diagnostics
        menu?.isHidden = true
        menu?.isUserInteractionEnabled = false
        addChild(diagnostics)
        diagnostics.view.frame = view.bounds
        diagnostics.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(diagnostics.view)
        diagnostics.didMove(toParent: self)
        view.bringSubviewToFront(diagnostics.view)
        diagnostics.startMonitoring()
    }

    private func requestLandscapeMode() {
        guard let windowScene = view.window?.windowScene else { return }
        windowScene.requestGeometryUpdate(
            .iOS(interfaceOrientations: [.landscapeLeft, .landscapeRight]),
            errorHandler: nil
        )
    }

    // MARK: Панель браузера в мире

    private func ensureBrowserAnchor(using cameraTransform: simd_float4x4) {
        guard inVR, !didCreateInitialAnchor else { return }
        guard !cinemaActive, !panoramaActive, !graffitiActive else { return }
        guard view.bounds.width > view.bounds.height, view.bounds.width > 100 else { return }

        let position = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        var forward = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            0,
            -cameraTransform.columns.2.z
        )
        if simd_length(forward) < 1e-4 {
            forward = SIMD3<Float>(0, 0, -1)
        }
        forward = simd_normalize(forward)

        let transform = panelTransform(
            center: position + forward * browserWorldDistance,
            forward: forward
        )
        browserWorldTransform = transform
        didCreateInitialAnchor = true
        commitAnchor()
        applyBrowserWorldTransform()
    }

    /// Панель всегда стоит вертикально: наклон головы не должен её заваливать.
    private func panelTransform(center: SIMD3<Float>, forward: SIMD3<Float>) -> simd_float4x4 {
        var flatForward = SIMD3<Float>(forward.x, 0, forward.z)
        if simd_length(flatForward) < 1e-4 {
            flatForward = SIMD3<Float>(0, 0, -1)
        }
        flatForward = simd_normalize(flatForward)

        let up = SIMD3<Float>(0, 1, 0)
        let rightAxis = simd_normalize(simd_cross(up, -flatForward))

        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4<Float>(rightAxis, 0)
        transform.columns.1 = SIMD4<Float>(up, 0)
        transform.columns.2 = SIMD4<Float>(-flatForward, 0)
        transform.columns.3 = SIMD4<Float>(center, 1)
        return transform
    }

    /// Перевешивает якорь на текущее положение панели. ARAnchor неизменяем,
    /// поэтому старый снимается, новый ставится.
    private func commitAnchor() {
        guard let transform = browserWorldTransform else { return }
        if let anchor = browserAnchor {
            tracking.remove(anchor: anchor)
        }
        let anchor = ARAnchor(name: "HandAR_Stereo_Browser", transform: transform)
        browserAnchor = anchor
        tracking.add(anchor: anchor)
    }

    private func applyBrowserWorldTransform() {
        guard let transform = browserWorldTransform else { return }
        // В кинотеатре экран позиционируется самим залом, а не AR-якорем.
        guard !cinemaActive else { return }
        browserPlaneNode.simdWorldTransform = transform
        // Во время Security VR браузерный слой должен оставаться скрытым:
        // иначе меню просвечивает сквозь игровую комнату.
        browserPlaneNode.isHidden = !inVR || securityGameActive || panoramaActive || graffitiActive
    }

    private func resetBrowserAnchor() {
        if timeMotionActive { timeMotion.recenterControls(head: headNode); return }
        if graffitiActive { graffiti.recenterControls(head: headNode); return }
        if panoramaActive { panorama.recenter(head: headNode); return }
        if cinemaActive { alignCinemaToCurrentPose(); return }
        if let anchor = browserAnchor {
            tracking.remove(anchor: anchor)
        }
        browserAnchor = nil
        browserWorldTransform = nil
        didCreateInitialAnchor = false
        isDragging = false
        browserPlaneNode.isHidden = true
    }

    private func startBrowserCapture() {
        stopBrowserCapture()
        guard inVR, !directVideoActive, !cinemaPlayback.isActive, !securityGameActive, !panoramaActive, !graffitiActive else { return }
        browserCaptureEnabled = true
        scheduleBrowserCapture()
    }

    private func scheduleBrowserCapture() {
        guard browserCaptureEnabled else { return }
        let budget = VRPerformanceBudget(thermalLevel: ProcessInfo.processInfo.thermalState.rawValue)
        let interval = budget.snapshotInterval(
            home: spatialHomeVisible, cinema: isCinemaMode,
            interacting: CACurrentMediaTime() - lastBrowserInteractionTime < 0.5
        )
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.browserCaptureEnabled else { return }
            self.updateBrowserSnapshot()
            self.scheduleBrowserCapture()
        }
        timer.tolerance = interval * 0.1
        browserTimer = timer
    }

    private func stopBrowserCapture() {
        browserCaptureEnabled = false
        snapshotGeneration = UUID()
        browserTimer?.invalidate()
        browserTimer = nil
    }

    private func updateBrowserSnapshot() {
        // Когда экран зала играет нативным плеером, снимки страницы не нужны:
        // они бы затирали кадры AVPlayer.
        guard inVR, !directVideoActive, !snapshotInProgress, !cinemaPlayback.isActive else { return }
        guard browser.bounds.width > 1, browser.bounds.height > 1 else { return }
        snapshotInProgress = true
        let generation = snapshotGeneration

        let configuration = WKSnapshotConfiguration()
        // Кинопанель почти вдвое шире обычной — тот же снимок на ней
        // размылился бы, поэтому берём его крупнее.
        configuration.snapshotWidth = NSNumber(value: spatialHomeVisible ? 960 : (isCinemaMode ? 1536 : 1280))
        browser.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotInProgress = false
            guard self.snapshotGeneration == generation, self.inVR, !self.directVideoActive, !self.cinemaPlayback.isActive,
                  let image else { return }
            self.browserMaterial.diffuse.contents = image
            self.browserMaterial.emission.contents = image
        }
    }

    // MARK: Руки и указатель

    private func setPointerControlMode(_ mode: PointerControlMode) {
        guard pointerControlMode != mode else { return }
        cancelHandInteraction()
        endDrag(); endResize()
        handOwnership.reset(); hands.reset(); menuSwipe.reset()
        pointerControlMode = mode; mode.save()
        controllerButtonDown = false
        controllerHandRoot.isHidden = true
        leftHandSkeletonNode.isHidden = true; rightHandSkeletonNode.isHidden = true
        hidePointer(); hidePointerDot()
        cinemaHall.setHeadAiming(usesHeadAim, head: headNode)
        menu?.updatePointerControlMode()
        updateVRDesktopStatus()
    }

    private func updateHeadAim(at time: Double) {
        guard inVR, usesHeadAim, lensCalibrationView == nil else { return }
        let frame = tracking.latestFrameCopy
        let ready = headAimSession.update(at: time, poseTime: frame?.timestamp ?? -.infinity,
                                          current: frame.map { tracking.isCurrent($0) } ?? false)
        guard ready else {
            // Do not reset the session's settling timer while waiting for it.
            releasePointer(); hidePointer(); hidePointerDot()
            cinemaHall.cancelInput(); securityGame.cancelInput(); panorama.cancelInput(); graffiti.cancelInput()
            toolbarClickGate.cancel()
            return
        }
        let transform = headNode.simdWorldTransform
        let forward = SIMD3<Float>(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
        guard forward.x.isFinite, forward.y.isFinite, forward.z.isFinite,
              simd_length(forward) > 0.001 else {
            headAimSession.reset(); cancelHandInteraction(); return
        }
        let ray = WorldRay(origin: headNode.simdWorldPosition, direction: simd_normalize(forward))
        controllerHandRoot.isHidden = true
        if graffitiActive {
            _ = graffiti.updateUI(ray: graffitiTrackingReady ? ray : nil, at: time)
        } else if panoramaActive {
            handlePanoramaRay(ray, down: false, allowBegin: false, dwell: true)
        } else if cinemaActive {
            // Looking at the film must never activate the video's pause surface.
            _ = cinemaHall.update(ray: ray, pinch: false, allowBegin: false, dwell: true)
            if cinemaWebScreenActive, !cinemaHall.comfort.isPeeking,
               let hit = planeHit(ray: ray, transform: cinemaHall.screenWorldTransform) {
                let uv = CGPoint(x: CGFloat(hit.localX / CinemaHall.screenWidth + 0.5),
                                 y: CGFloat(0.5 - hit.localY / CinemaHall.screenHeight))
                updateCinemaWebPointers((0...1).contains(uv.x) && (0...1).contains(uv.y) ? uv : nil)
            } else { updateCinemaWebPointers(nil) }
        } else if securityGameActive {
            securityGame.update(ray: ray, pinch: false, allowBegin: false, dwell: true)
        } else {
            handleWindowRay(ray, down: false, allowBegin: false, dwell: true, at: time)
        }
        if inVR, usesHeadAim {
            showPointerDot(at: ray.point(at: 0.9), transform: transform, active: false)
            rayNode.isHidden = true
        }
    }

    private func handleControllerStick(x: CGFloat, y: CGFloat) {
        guard !usesHeadAim || lensCalibrationView != nil else { return }
        guard inVR, controllerConnected else { return }
        guard CACurrentMediaTime() - lastHandSeenTime > 0.45 else { return }
        let dead: CGFloat = 0.12
        let sx = abs(x) < dead ? 0 : x
        let sy = abs(y) < dead ? 0 : y
        guard sx != 0 || sy != 0 else {
            updateControllerHand()
            return
        }
        let speed: CGFloat = 0.018
        controllerPointer.x = min(max(controllerPointer.x + sx * speed, 0.015), 0.985)
        controllerPointer.y = min(max(controllerPointer.y + sy * speed, 0.015), 0.985)
        updateControllerHand()
    }

    private func handleControllerGyro(_ rate: SIMD3<Float>) {
        guard !usesHeadAim || lensCalibrationView != nil else { return }
        guard inVR, controllerConnected else { return }
        guard CACurrentMediaTime() - lastHandSeenTime > 0.45 else { return }
        let dt: CGFloat = 1.0 / 30.0
        let sensitivity: CGFloat = 1.25
        let dx = CGFloat(rate.y) * dt * sensitivity
        let dy = CGFloat(rate.x) * dt * sensitivity
        controllerPointer.x = min(max(controllerPointer.x + dx, 0.015), 0.985)
        controllerPointer.y = min(max(controllerPointer.y - dy, 0.015), 0.985)
        updateControllerHand()
    }

    private func handleControllerButton(_ button: VRBoxButton, pressed: Bool) {
        if graffitiActive {
            if pressed, button == .menu || button == .b { exitGraffiti() }
            if pressed, button == .y { graffiti.recenterControls(head: headNode) }
            return
        }
        if usesHeadAim, lensCalibrationView == nil {
            if button == .menu, pressed { leaveVRToMenu() }
            return
        }
        guard inVR, controllerConnected else { return }
        guard CACurrentMediaTime() - lastHandSeenTime > 0.45 else { return }
        if lensCalibrationView != nil {
            switch button {
            case .a: controllerButtonDown=pressed;updateControllerHand()
            case .b, .x, .menu: if pressed {finishLensCalibration()}
            default: break
            }
            return
        }
        if panoramaActive {
            switch button {
            case .a: controllerButtonDown = pressed; updatePanoramaController()
            case .b, .x: if pressed { exitPanorama() }
            case .y: if pressed { panorama.recenter(head: headNode) }
            case .menu: if pressed { leaveVRToMenu() }
            }
            return
        }
        if cinemaActive {
            switch button {
            case .a: controllerButtonDown = pressed; updateCinemaController()
            case .b: if pressed { toggleCinemaPeek(); playUIConfirmation() }
            case .x: if pressed { toggleCinemaRemote(); playUIConfirmation() }
            case .y: if pressed { alignCinemaToCurrentPose(); playUIConfirmation() }
            case .menu: if pressed { leaveVRToMenu() }
            }
            return
        }
        switch button {
        case .a:
            controllerButtonDown = pressed
            updateControllerHand()
        case .b:
            if pressed {
                if directVideoActive {
                    if cinemaActive { closeDirectVideo() } else { navigateLiveBrowser(back: true) }
                } else if browser.canGoBack {
                    browser.goBack()
                }
            }
        case .x:
            if pressed {
                if directVideoActive { closeDirectVideo() } else { openVRDesktop() }
            }
        case .y:
            if pressed { resetBrowserAnchor(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        case .menu:
            if pressed { leaveVRToMenu() }
        }
    }

    private func updateControllerHand() {
        if graffitiActive { controllerHandRoot.isHidden = true; return }
        guard !usesHeadAim || lensCalibrationView != nil else { return }
        if let calibration=lensCalibrationView {
            calibration.updatePointer(CGPoint(x:controllerPointer.x*view.bounds.width*0.5,y:controllerPointer.y*view.bounds.height),
                down:controllerButtonDown,dwell:false,time:CACurrentMediaTime())
            return
        }
        if panoramaActive { updatePanoramaController(); return }
        if cinemaActive {
            updateCinemaController()
            return
        }
        guard inVR, controllerConnected, let transform = browserWorldTransform else {
            controllerHandRoot.isHidden = true
            return
        }
        let x = min(max(controllerPointer.x, 0), 1)
        let y = min(max(controllerPointer.y, 0), 1)
        let local = SIMD3<Float>(
            Float(x - 0.5) * browserWorldWidth,
            Float(0.5 - y) * browserWorldHeight,
            0.035
        )
        let world4 = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
        let world = SIMD3<Float>(world4.x, world4.y, world4.z)
        let towardCamera = simd_normalize(headNode.simdWorldPosition - world)
        controllerHandRoot.simdWorldPosition = world + towardCamera * 0.13
        controllerHandRoot.simdWorldOrientation = browserPlaneNode.simdWorldOrientation
        controllerHandTip.simdWorldPosition = world + towardCamera * 0.02
        controllerHandRoot.isHidden = false
        showPointerDot(at: world, transform: transform, active: controllerButtonDown)
        showRay(
            from: WorldRay(origin: headNode.simdWorldPosition, direction: simd_normalize(world - headNode.simdWorldPosition)),
            hit: world
        )
        lastBrowserInteractionTime = CACurrentMediaTime()
        if directVideoActive {
            updateDirectVideoInput(normalizedPoint: CGPoint(x: x, y: y), pinch: controllerButtonDown)
        } else {
            input.update(normalizedPoint: CGPoint(x: x, y: y), pinch: controllerButtonDown, webView: browser)
        }
    }

    private func updateDirectVideoInput(normalizedPoint: CGPoint, pinch: Bool, allowBegin: Bool = true, dwell: Bool = false) {
        updateCinemaWebPointers(normalizedPoint)
        guard cinemaWebPointers.contains(where: { !$0.isHidden }) else {
            directLeftInput.release(webView:directVideoLeft)
            return
        }
        // Only the source DOM receives input; its visual result is copied.
        directLeftInput.update(normalizedPoint: normalizedPoint, pinch: pinch, webView: directVideoLeft, allowBegin:allowBegin, dwell:dwell)
    }

    private func cancelHandInteraction() {
        headAimSession.reset()
        lensCalibrationView?.cancelInteraction()
        input.release(webView: browser)
        directLeftInput.release(webView: directVideoLeft)
        cinemaHall.cancelInput()
        securityGame.cancelInput()
        timeMotion.cancelInput()
        panorama.cancelInput()
        graffiti.cancelInput()
        toolbarClickGate.cancel()
        toolbarDwellRing.isHidden=true
        updateCinemaWebPointers(nil)
    }

    private func handleHands(left rawLeft: HandSample?, right rawRight: HandSample?) {
        guard inVR, !usesHeadAim || lensCalibrationView != nil || graffitiActive else { return }
        let now = CACurrentMediaTime()
        let freshLeft = rawLeft.flatMap { now-$0.timestamp <= 0.2 && now >= $0.timestamp && tracking.acceptsHand(timestamp:$0.timestamp) ? $0 : nil }
        let freshRight = rawRight.flatMap { now-$0.timestamp <= 0.2 && now >= $0.timestamp && tracking.acceptsHand(timestamp:$0.timestamp) ? $0 : nil }
        if timeMotionActive {
            timeMotionLeft = freshLeft
            timeMotionRight = freshRight
            controllerHandRoot.isHidden = true
            return
        }
        lastHandDeliveryTime = max(freshLeft?.timestamp ?? -.infinity, freshRight?.timestamp ?? -.infinity)
        if securityGameActive {
            let samples = [freshRight,freshLeft].compactMap { $0 }
            let sample = samples.first { $0.hand == securityGame.inputHand } ?? samples.first
            if let sample { lastHandSeenTime = now }
            else if controllerConnected, now-lastHandSeenTime > 0.45 { updateControllerHand(); return }
            var ray: WorldRay?
            if let sample, let wrist = sample.maskJoints[.wrist], let base = sample.maskJoints[.middleMCP] {
                ray = tracking.worldRay(visionPoint:CGPoint(x:(wrist.x+base.x)*0.5,y:(wrist.y+base.y)*0.5))
            }
            securityGame.update(ray:ray,pinch:sample?.clickPinch ?? false,allowBegin:sample?.clickBegan ?? false,
                                dwell:usesDwell,fist:sample?.isFist,open:sample?.openPalmCenter != nil,
                                hand:sample?.hand,trackingGeneration:sample?.trackingGeneration)
            controllerHandRoot.isHidden = true
            return
        }
        if freshLeft != nil || freshRight != nil { lastHandSeenTime = now }
        if graffitiActive {
            handleGraffitiHands(left: freshLeft, right: freshRight, at: now)
            let removeRealHands = graffitiActive && graffiti.mode == .home && graffitiTrackingReady
            queueHandForegroundMask(left: removeRealHands ? freshLeft : nil,
                                    right: removeRealHands ? freshRight : nil, removing: removeRealHands)
            return
        }
        if lensCalibrationView == nil && !directVideoActive && !cinemaActive && !panoramaActive { queueHandForegroundMask(left:freshLeft,right:freshRight) }
        if spatialHomeVisible, !cinemaActive, !securityGameActive, !panoramaActive, lensCalibrationView == nil,
           !isDragging, !isResizing {
            let sample = [freshRight,freshLeft].compactMap{$0}.first{$0.openPalmCenter != nil}
            let point=sample?.openPalmCenter
            let direction=menuSwipe.update(hand:sample?.hand,point:point.map{SIMD2(Double($0.x),Double($0.y))},at:now)
            if let direction {
                browser.evaluateJavaScript("window.__handarSwipePage && window.__handarSwipePage(\(direction));") { [weak self] changed,_ in
                    if changed as? Bool == true { self?.playUIConfirmation() }
                }
            }
            if menuSwipe.isMoving {
                cancelHandInteraction(); endDrag(); hidePointer(); hidePointerDot()
                return
            }
        } else { menuSwipe.reset() }
        // Resizing consumes both pinches; neither may turn into a click afterward.
        if lensCalibrationView == nil, !cinemaActive, !securityGameActive, !panoramaActive,
           let left = freshLeft, let right = freshRight, left.clickPinch, right.clickPinch {
            cancelHandInteraction()
            handOwnership.suppressUntilOpen()
            endDrag()
            updateResize(left:left,right:right)
            return
        }
        if isResizing {
            endResize()
            cancelHandInteraction()
            handOwnership.suppressUntilOpen()
        }
        // Dwell needs a fresh index and palm, not thumb contact or its generation.
        // A missing fingertip must not redirect a dwell to a cached palm cursor.
        func eligible(_ sample: HandSample?) -> HandSample? {
            guard let sample else { return nil }
            return !usesDwell || sample.isFist || sample.maskJoints[.indexTip] != nil ? sample : nil
        }
        let inputLeft=eligible(freshLeft), inputRight=eligible(freshRight)
        func route(_ sample: HandSample?) -> HandRoutingState? {
            guard let sample else { return nil }
            return usesDwell ? HandRoutingState(hand:sample.hand,generation:0,down:sample.clickPinch,openConfirmed:!sample.clickPinch) : sample.routing
        }
        let decision = handOwnership.select(left:route(inputLeft),right:route(inputRight))
        if decision.cancel { cancelHandInteraction() }
        if decision.changedHand { endDrag() }
        let selected = decision.hand == .left ? inputLeft : (decision.hand == .right ? inputRight : nil)
        let routed = selected?.routed(down:decision.down,began:decision.began)
        let left = decision.hand == .left ? routed : nil
        let right = decision.hand == .right ? routed : nil
        // Empty Vision updates must not cancel a controller's active press.
        if routed == nil, controllerConnected, now-lastHandSeenTime > 0.45 {
            updateControllerHand()
            return
        }
        if lensCalibrationView != nil {
            updateCalibrationHand(routed)
            return
        }
        if let sample=routed, sample.isFist, cinemaActive || securityGameActive || panoramaActive {
            cancelHandInteraction()
            return
        }
        if panoramaActive {
            let sample = right ?? left
            let ray = sample.flatMap { tracking.worldRay(visionPoint: $0.indexTip) }
            handlePanoramaRay(ray, down: sample?.clickPinch ?? false,
                              allowBegin: sample?.clickBegan ?? false, dwell: usesDwell)
            controllerHandRoot.isHidden = true
            return
        }
        if cinemaWebScreenActive {
            handleCinemaWebHands(left: left, right: right)
            return
        }

        if cinemaActive {
            handleCinemaWebHands(left: left, right: right)
            controllerHandRoot.isHidden = true
            return
        }

        if left != nil || right != nil {
            lastHandSeenTime = CACurrentMediaTime()
            controllerHandRoot.isHidden = true
        }

        guard
            let sample = right ?? left,
            let ray = tracking.worldRay(visionPoint: sample.indexTip)
        else {
            endDrag()
            releasePointer()
            hidePointer()
            if controllerConnected && CACurrentMediaTime() - lastHandSeenTime > 0.45 {
                updateControllerHand()
            } else {
                controllerHandRoot.isHidden = true
            }
            return
        }

        // A fist grabs the panel under its ray; it never shares the click pinch.
        let grabHit = browserWorldTransform.flatMap { planeHit(ray:ray,transform:$0) }
        let inDragZone = grabHit.map { abs($0.localX) <= browserWorldWidth*0.5 && abs($0.localY) <= browserWorldHeight*0.5+0.06 } ?? false
        if sample.isFist {
            cancelHandInteraction()
            if isDragging || inDragZone { updateDrag(with: ray) }
            else { endDrag() }
            releasePointer()
            highlightToolbar(nil)
            pointerNode.isHidden = true
            return
        }
        endDrag()

        handleWindowRay(ray, down: sample.clickPinch, allowBegin: sample.clickBegan, dwell: usesDwell, at: now)
    }

    private func handleWindowRay(_ ray: WorldRay, down: Bool, allowBegin: Bool, dwell: Bool, at now: Double) {
        guard let transform = browserWorldTransform else {
            toolbarClickGate.cancel()
            showRay(from: ray, hit: nil)
            hidePointerDot()
            releasePointer()
            return
        }

        guard let hit = planeHit(ray: ray, transform: transform) else {
            toolbarClickGate.cancel()
            showRay(from: ray, hit: nil)
            hidePointerDot()
            releasePointer()
            highlightToolbar(nil)
            return
        }

        showRay(from: ray, hit: hit.point)
        showPointerDot(at: hit.point, transform: transform, active: down)

        // The shared toolbar stays below the window during browser playback.
        // Invisible controls (e.g. in the hall) must not receive a hit.
        if !isCinemaMode, !toolbarNode.isHidden, abs(hit.localY - toolbarCenterY) <= toolbarButtonHeight * 0.5 {
            let index = linkItems.firstIndex { hit.localX >= $0.minX && hit.localX <= $0.maxX }
            highlightToolbar(index)
            releasePointer()
            let committed=toolbarClickGate.update(target:index,down:down,allowBegin:allowBegin,dwell:dwell,at:now)
            toolbarDwellRing.show(on:index.map { toolbarButtonNodes[$0] },progress:toolbarClickGate.dwellProgress)
            if let index = committed {
                perform(item:linkItems[index])
                UIImpactFeedbackGenerator(style:.rigid).impactOccurred()
            }
            return
        }
        highlightToolbar(nil)
        toolbarClickGate.cancel()

        let normalizedX = hit.localX / browserWorldWidth + 0.5
        let normalizedY = 0.5 - hit.localY / browserWorldHeight
        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else {
            releasePointer()
            return
        }

        lastBrowserInteractionTime = CACurrentMediaTime()
        let uv = CGPoint(x: CGFloat(normalizedX), y: CGFloat(normalizedY))
        if directVideoActive {
            updateDirectVideoInput(normalizedPoint: uv, pinch: down, allowBegin: allowBegin, dwell: dwell)
        } else {
            input.update(normalizedPoint: uv, pinch: down, webView: browser,
                         allowBegin: allowBegin, dwell: dwell)
        }
    }

    private func updateResize(left: HandSample, right: HandSample) {
        let distance = distance(left.indexTip, right.indexTip)
        guard distance > 0.06 else { return }

        if !isResizing {
            isResizing = true
            resizeStartHandDistance = distance
            resizeStartWidth = browserWorldWidth
            isCinemaMode = false
            toolbarNode.isHidden = false
            input.release(webView: browser)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }

        guard resizeStartHandDistance > 0.001 else { return }
        let scale = max(0.45, min(2.5, distance / resizeStartHandDistance))
        let width = max(
            Self.minimumPanelWidth,
            min(Self.maximumPanelWidth, resizeStartWidth * Float(scale))
        )
        updatePanelSize(width: width)
    }

    private func endResize() {
        guard isResizing else { return }
        isResizing = false
        resizeStartHandDistance = 0
        UserDefaults.standard.set(Double(browserWorldWidth), forKey: SpatialWindowSizing.storageKey)
        commitAnchor()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func updatePanelSize(width: Float) {
        browserWorldWidth = max(Self.minimumPanelWidth, min(Self.maximumPanelWidth, width))
        browserWorldHeight = browserWorldWidth * Self.defaultPanelAspect

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        browserPlaneGeometry.width = CGFloat(browserWorldWidth)
        browserPlaneGeometry.height = CGFloat(browserWorldHeight)
        browserFrameGeometry.width = CGFloat(browserWorldWidth) + 0.018
        browserFrameGeometry.height = CGFloat(browserWorldHeight) + 0.018
        browserHandleNode.position = SCNVector3(0, -Double(browserWorldHeight) * 0.5 - 0.028, 0)

        let gap: Float = 0.014
        let count = Float(toolbarButtonNodes.count)
        if count > 0 {
            let buttonWidth = min(0.42, max(0.06, (browserWorldWidth - gap * (count - 1)) / count))
            toolbarCenterY = -browserWorldHeight * 0.5 - 0.085 - toolbarButtonHeight * 0.5
            for index in toolbarButtonNodes.indices {
                let minX = -(buttonWidth * count + gap * (count - 1)) * 0.5 + Float(index) * (buttonWidth + gap)
                linkItems[index].minX = minX
                linkItems[index].maxX = minX + buttonWidth
                if let plane = toolbarButtonNodes[index].geometry as? SCNPlane {
                    plane.width = CGFloat(buttonWidth)
                }
                toolbarButtonNodes[index].position = SCNVector3(
                    Double(minX + buttonWidth * 0.5),
                    Double(toolbarCenterY),
                    0.003
                )
            }
        }
        SCNTransaction.commit()
        startBrowserCapture()
    }

    private func playUIConfirmation() {
        guard inVR, CACurrentMediaTime() - lastConfirmationTime >= 0.08 else { return }
        lastConfirmationTime = CACurrentMediaTime()
        confirmationPlayer?.currentTime = 0
        confirmationPlayer?.play()
    }

    private func perform(item: ToolbarItem) {
        playUIConfirmation()
        switch item.action {
        case .open(let url):
            openExternalPage(url)
        case .back:
            if directVideoActive { navigateLiveBrowser(back: true) }
            else if browser.canGoBack { browser.goBack() }
        case .home:
            if directVideoActive { closeDirectVideo() } else { openVRDesktop() }
        case .center:
            resetBrowserAnchor()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .reload:
            if directVideoActive { navigateLiveBrowser(back: false) } else { browser.reload() }
        case .size:
            releasePointer()
            let width = SpatialWindowSizing.nextWidth(after: browserWorldWidth)
            updatePanelSize(width: width)
            UserDefaults.standard.set(Double(width), forKey: SpatialWindowSizing.storageKey)
        }
    }

    /// Создаёт маску кисти в координатах сырого кадра камеры. В ней нет
    /// графики скелета. Обычная маска показывает руку поверх сцены; расширенная
    /// маска в домашних стенах Граффити используется для замены руки фоном.
    private func queueHandForegroundMask(left: HandSample?, right: HandSample?, removing: Bool = false) {
        let now = CACurrentMediaTime()
        let activeSamples = [left, right].compactMap { $0 }.filter { VirtualHandPose.fresh($0.timestamp, at: now) }
        if activeSamples.isEmpty {
            handMaskLock.lock()
            let alreadyClear = !pendingHandMaskActive
            handMaskLock.unlock()
            if alreadyClear { return }
        }
        var bytes = [UInt8](repeating: 0, count: handMaskWidth * handMaskHeight)
        guard !activeSamples.isEmpty,
              let context = CGContext(
                data: &bytes,
                width: handMaskWidth,
                height: handMaskHeight,
                bitsPerComponent: 8,
                bytesPerRow: handMaskWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: 0
              ) else {
            handMaskLock.lock()
            pendingHandMaskBytes = bytes
            pendingHandMaskActive = false
            handMaskNeedsUpload = true
            handMaskLock.unlock()
            return
        }

        // Vision/камера используют верхний левый угол как начало UV в нашей схеме.
        context.translateBy(x: 0, y: CGFloat(handMaskHeight))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(UIColor.white.cgColor)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        var active = false
        for sample in activeSamples { if drawHandMask(sample, in: context, removing: removing) { active = true } }

        handMaskLock.lock()
        pendingHandMaskBytes = bytes
        pendingHandMaskActive = active
        handMaskTimestamp = activeSamples.map(\.timestamp).min() ?? -.infinity
        handMaskNeedsUpload = true
        handMaskLock.unlock()
    }

    private func drawHandMask(_ sample: HandSample, in context: CGContext, removing: Bool = false) -> Bool {
        let landscapeLeft = currentInterfaceOrientation() == .landscapeLeft
        // Build in real camera pixels: a square UV texture must not widen fingers
        // along the long side of a landscape camera frame.
        func point(_ name: VNHumanHandPoseObservation.JointName) -> SIMD2<Double>? {
            guard let p = sample.maskJoints[name], p.x.isFinite, p.y.isFinite,
                  (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
            return SIMD2(landscapeLeft ? 1-Double(p.x) : Double(p.x),
                         landscapeLeft ? Double(p.y) : 1-Double(p.y)) * sample.imageSize
        }
        let chains: [[VNHumanHandPoseObservation.JointName]] = [
            [.thumbCMC,.thumbMP,.thumbIP,.thumbTip], [.indexMCP,.indexPIP,.indexDIP,.indexTip],
            [.middleMCP,.middlePIP,.middleDIP,.middleTip], [.ringMCP,.ringPIP,.ringDIP,.ringTip],
            [.littleMCP,.littlePIP,.littleDIP,.littleTip]
        ]
        guard let silhouette = HandSilhouette.make(wrist:point(.wrist), fingers:chains.map { $0.map(point) }) else { return false }
        let shape = removing ? silhouette.removalEnvelope() : silhouette
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x:CGFloat(Double(handMaskWidth)/sample.imageSize.x),
                        y:CGFloat(Double(handMaskHeight)/sample.imageSize.y))
        func cg(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x:p.x,y:p.y) }
        func fill(_ points: [SIMD2<Double>]) {
            guard let first = points.first else { return }
            let path = CGMutablePath()
            path.move(to:cg(first))
            for p in points.dropFirst() { path.addLine(to:cg(p)) }
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }
        func disc(_ p: SIMD2<Double>, _ r: Double) {
            context.fillEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2))
        }
        fill(shape.palm)
        for segment in shape.segments {
            let delta = segment.end-segment.start
            let normal = SIMD2(-delta.y,delta.x)/HandPinchGeometry.distance(segment.start,segment.end)
            let a = normal*segment.startRadius, b = normal*segment.endRadius
            fill([segment.start+a,segment.end+b,segment.end-b,segment.start-a])
            disc(segment.start,segment.startRadius)
            disc(segment.end,segment.endRadius)
        }
        return true
    }

    private func syncHandMaskTexture() -> Bool {
        guard let texture = handMaskTexture else { return false }
        handMaskLock.lock()
        // Never leave an old cutout over a newer live camera image after a stall.
        let age = CACurrentMediaTime() - handMaskTimestamp
        let active = pendingHandMaskActive && age >= 0 && age <= 0.12
        guard handMaskNeedsUpload else {
            handMaskLock.unlock()
            return active
        }
        handMaskNeedsUpload = false
        let bytes = pendingHandMaskBytes
        handMaskLock.unlock()

        guard !bytes.isEmpty else { return false }
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, handMaskWidth, handMaskHeight),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: handMaskWidth
            )
        }
        return active
    }

    private func updateHandSkeleton(left: HandSample?, right: HandSample?) {
        updateSingleHandSkeleton(sample: left, root: leftHandSkeletonNode, joints: leftSkeletonJoints, bones: leftSkeletonBones, palm: leftPalmNode)
        updateSingleHandSkeleton(sample: right, root: rightHandSkeletonNode, joints: rightSkeletonJoints, bones: rightSkeletonBones, palm: rightPalmNode)
    }

    private func updateSingleHandSkeleton(
        sample: HandSample?,
        root: SCNNode,
        joints: [VNHumanHandPoseObservation.JointName: SCNNode],
        bones: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, SCNNode)],
        palm: SCNNode?
    ) {
        guard let sample, let transform = browserWorldTransform else {
            root.isHidden = true
            return
        }

        var positions: [VNHumanHandPoseObservation.JointName: SIMD3<Float>] = [:]
        positions.reserveCapacity(sample.joints.count)

        for (jointName, visionPoint) in sample.joints {
            guard let ray = tracking.worldRay(visionPoint: visionPoint),
                  let hit = planeHit(ray: ray, transform: transform) else { continue }
            let towardCamera = simd_normalize(ray.origin - hit.point)
            positions[jointName] = hit.point + towardCamera * 0.018
        }

        guard positions.count >= 3 else {
            root.isHidden = true
            return
        }

        var shown = false
        for (jointName, node) in joints {
            guard let point = positions[jointName] else {
                node.isHidden = true
                continue
            }
            node.simdPosition = point
            node.isHidden = false
            shown = true
        }

        for (a, b, node) in bones {
            guard let start = positions[a], let end = positions[b] else {
                node.isHidden = true
                continue
            }
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.002 else {
                node.isHidden = true
                continue
            }
            node.simdPosition = (start + end) * 0.5
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            node.scale = SCNVector3(1, length, 1)
            node.isHidden = false
        }

        // Ладонь: центр — середина между запястьём и средним MCP,
        // ось Y — от запястья к среднему MCP, толщина мала (плоская рука).
        if let palm,
           let wrist = positions[.wrist],
           let middleMCP = positions[.middleMCP] {
            let axis = middleMCP - wrist
            let axisLen = simd_length(axis)
            let indexMCP = positions[.indexMCP]
            let littleMCP = positions[.littleMCP]
            let palmWidth = (indexMCP != nil && littleMCP != nil)
                ? simd_length(indexMCP! - littleMCP!) * 0.62
                : axisLen * 0.85
            guard axisLen > 0.01 else {
                palm.isHidden = true
                root.isHidden = !shown
                return
            }
            let midPoint = (wrist + middleMCP) * 0.5
            palm.simdPosition = midPoint
            palm.simdOrientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: axis / axisLen
            )
            palm.scale = SCNVector3(
                palmWidth,
                axisLen * 0.72,
                0.011
            )
            palm.isHidden = false
        } else {
            palm?.isHidden = true
        }

        root.isHidden = !shown
    }

    private func planeHit(
        ray: WorldRay,
        transform: simd_float4x4
    ) -> (point: SIMD3<Float>, localX: Float, localY: Float)? {
        let center = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        let rightAxis = simd_normalize(SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        ))
        let upAxis = simd_normalize(SIMD3<Float>(
            transform.columns.1.x,
            transform.columns.1.y,
            transform.columns.1.z
        ))
        let normal = simd_normalize(SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        ))

        let denominator = simd_dot(ray.direction, normal)
        guard abs(denominator) > 1e-5 else { return nil }

        let distance = simd_dot(center - ray.origin, normal) / denominator
        guard distance > 0.05, distance < 12 else { return nil }

        let point = ray.point(at: distance)
        let delta = point - center
        return (point, simd_dot(delta, rightAxis), simd_dot(delta, upAxis))
    }

    private func updateDrag(with ray: WorldRay) {
        guard let transform = browserWorldTransform else { return }
        let center = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )

        if !isDragging {
            isDragging = true
            dragDistance = max(0.55, min(5.0, simd_length(center - ray.origin)))
            // Запоминаем смещение, иначе панель прыгнет к пальцу в момент захвата.
            dragOffset = center - ray.point(at: dragDistance)
            input.release(webView: browser)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }

        var moved = transform
        moved.columns.3 = SIMD4<Float>(ray.point(at: dragDistance) + dragOffset, 1)
        browserWorldTransform = moved
        applyBrowserWorldTransform()

        // Луч тянется к панели, пока её тащат.
        showRay(from: ray, hit: SIMD3<Float>(
            moved.columns.3.x,
            moved.columns.3.y,
            moved.columns.3.z
        ))
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        commitAnchor()
    }

    private func showRay(from ray: WorldRay, hit: SIMD3<Float>?) {
        let start = ray.point(at: fingerRayOrigin)
        let end = hit ?? ray.point(at: fingerRayOrigin + 2.2)
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.01 else {
            rayNode.isHidden = true
            return
        }

        rayNode.simdPosition = (start + end) * 0.5
        rayNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
        rayNode.scale = SCNVector3(1, Float(length), 1)
        rayNode.isHidden = false
    }

    private func showPointerDot(at point: SIMD3<Float>, transform: simd_float4x4, active: Bool) {
        let rightAxis = simd_normalize(SIMD3<Float>(
            transform.columns.0.x,
            transform.columns.0.y,
            transform.columns.0.z
        ))
        let normal = simd_normalize(SIMD3<Float>(
            transform.columns.2.x,
            transform.columns.2.y,
            transform.columns.2.z
        ))

        // Диск и кольцо строятся вдоль своей локальной Y, поэтому Y кладём
        // на нормаль панели — иначе точка встанет ребром.
        var basis = matrix_identity_float4x4
        basis.columns.0 = SIMD4<Float>(rightAxis, 0)
        basis.columns.1 = SIMD4<Float>(normal, 0)
        basis.columns.2 = SIMD4<Float>(simd_cross(rightAxis, normal), 0)
        basis.columns.3 = SIMD4<Float>(point + normal * 0.006, 1)

        pointerNode.simdTransform = basis
        pointerNode.isHidden = false

        let color: UIColor = active
            ? UIColor(red: 1.0, green: 0.48, blue: 0.36, alpha: 1)
            : .white
        pointerDotNode.geometry?.firstMaterial?.diffuse.contents = color
        pointerDotNode.geometry?.firstMaterial?.emission.contents = color
        pointerNode.simdScale = SIMD3<Float>(repeating: active ? 0.82 : 1.0)
    }

    private func highlightToolbar(_ index: Int?) {
        if index == nil { toolbarDwellRing.isHidden=true }
        guard highlightedToolbarIndex != index else { return }
        let previous = highlightedToolbarIndex
        highlightedToolbarIndex = index
        // Only the old and new selections change; all textures were built once.
        for position in [previous, index].compactMap({ $0 }) {
            guard toolbarButtonNodes.indices.contains(position), toolbarImages.indices.contains(position) else { continue }
            let image = position == index ? toolbarImages[position].highlighted : toolbarImages[position].normal
            let material = toolbarButtonNodes[position].geometry?.firstMaterial
            material?.diffuse.contents = image
            material?.emission.contents = image
        }
    }

    private func hidePointerDot() {
        pointerNode.isHidden = true
    }

    private func hidePointer() {
        rayNode.isHidden = true
        pointerNode.isHidden = true
        highlightToolbar(nil)
    }

    private func releasePointer() {
        input.release(webView: browser)
        if directVideoActive {
            directLeftInput.release(webView: directVideoLeft)
            updateCinemaWebPointers(nil)
        }
    }

    private func showAlert(_ message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "HandAR Vision",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Рендер

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        eyeTexture = nil
    }

    func draw(in view: MTKView) {
        guard
            inVR,
            let compositor,
            let drawable = view.currentDrawable,
            let passDescriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }
        if graffitiActive {
            graffiti.updateFeet(head: headNode, at: CACurrentMediaTime(), ready: graffitiTrackingReady)
            graffiti.tick(at: CACurrentMediaTime(), trackingReady: graffitiTrackingReady)
            virtualHands.tick(at: CACurrentMediaTime(), ready: graffitiTrackingReady, head: headNode)
        }
        panorama.followPosition(head: headNode)
        updateHeadAim(at: CACurrentMediaTime())
        tickTimeMotion(at: CACurrentMediaTime())
        tickCinemaComfort(at: CACurrentMediaTime())
        if directVideoActive { updateCinemaWebScreen() }
        updateCinemaControlOcclusion()

        ensureEyeTextures(for: drawableSize)
        guard let eyeTexture, let eyeDepthTexture else { return }

        let time = CACurrentMediaTime()
        let eyeWidth = eyeTexture.width / 2
        let eyeHeight = eyeTexture.height

        // Проход 1 — левый глаз. Фон прозрачный: видео подложит композитор.
        let leftPass = MTLRenderPassDescriptor()
        leftPass.colorAttachments[0].texture = eyeTexture
        leftPass.colorAttachments[0].loadAction = .clear
        leftPass.colorAttachments[0].storeAction = .store
        leftPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        leftPass.depthAttachment.texture = eyeDepthTexture
        leftPass.depthAttachment.loadAction = .clear
        leftPass.depthAttachment.storeAction = .dontCare
        leftPass.depthAttachment.clearDepth = 1.0

        leftRenderer.pointOfView = leftCameraNode
        leftRenderer.render(
            atTime: time,
            viewport: CGRect(x: 0, y: 0, width: CGFloat(eyeWidth), height: CGFloat(eyeHeight)),
            commandBuffer: commandBuffer,
            passDescriptor: leftPass
        )

        // No second render: the compositor copies the left source into both eyes.

        // Проход 3 — оптика линз плюс сквозное видео.
        let frame = tracking.latestFrameCopy
        let handMaskActive = !panoramaActive && !graffitiActive && cameraPassthroughRequested && syncHandMaskTexture()
        let handRemovalActive = graffitiActive && graffiti.mode == .home && graffitiTrackingReady && syncHandMaskTexture()
        let cameraTextures = makeCameraTextures(from: frame, includeHands: handMaskActive)
        let uniforms = makeUniforms(
            drawableSize: drawableSize,
            frame: frame,
            hasCamera: cameraTextures != nil,
            handMaskActive: handMaskActive,
            handRemovalActive: handRemovalActive
        )

        let handMaskTexture = handMaskTexture ?? eyeTexture
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            compositor.encode(
                into: encoder,
                eyeTexture: eyeTexture,
                cameraY: cameraTextures?.0,
                cameraCbCr: cameraTextures?.1,
                handMask: handMaskTexture,
                uniforms: uniforms
            )
            encoder.endEncoding()
        }

        // Each submitted frame owns its wrappers until that GPU command completes.
        let frameTextures = retainedCameraTextures
        retainedCameraTextures.removeAll()
        commandBuffer.addCompletedHandler { [frameTextures] _ in
            withExtendedLifetime(frameTextures) {}
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms(
        drawableSize: CGSize,
        frame: CameraFrame?,
        hasCamera: Bool,
        handMaskActive: Bool = false,
        handRemovalActive: Bool = false
    ) -> VRUniforms {
        var uniforms = VRUniforms()
        uniforms.lensCenterL = VRLensMath.lensCenterUV(eye: 0, profile: profile)
        uniforms.lensCenterR = VRLensMath.lensCenterUV(eye: 1, profile: profile)
        uniforms.aspect = Float((drawableSize.width * 0.5) / max(drawableSize.height, 1))
        uniforms.k1 = profile.k1
        uniforms.k2 = profile.k2
        uniforms.chroma = profile.chroma
        // Full rectangular eye view; overscan preserves the calibrated lens warp.
        uniforms.rClip = 10
        uniforms.overscan = VRLensMath.renderScale(profile:profile,aspect:uniforms.aspect)
        uniforms.passthrough = (cameraPassthroughRequested && hasCamera) ? 1 : 0

        guard let frame, hasCamera else { return uniforms }

        guard let projection = tracking.projection(for: frame) else {
            uniforms.passthrough = 0
            return uniforms
        }

        uniforms.handRemovalEnabled = (handRemovalActive && graffitiActive && graffiti.mode == .home && uniforms.passthrough > 0.5) ? 1 : 0
        uniforms.handMaskEnabled = (handMaskActive && !graffitiActive && uniforms.handRemovalEnabled == 0) ? 1 : 0

        let flip = currentInterfaceOrientation() == .landscapeLeft

        let left = fullEyeFrustum(eye: 0, aspect: uniforms.aspect)
        let right = fullEyeFrustum(eye: 1, aspect: uniforms.aspect)
        let mappedLeft = cameraMapping(for:left,projection:projection,flipped:flip)
        let mappedRight = cameraMapping(for:right,projection:projection,flipped:flip)

        uniforms.camScaleL = mappedLeft.scale
        uniforms.camOffsetL = mappedLeft.offset
        uniforms.camScaleR = mappedRight.scale
        uniforms.camOffsetR = mappedRight.offset
        return uniforms
    }

    /// Same projection model as hand rays, including the wider 0.5x view.
    private func cameraMapping(
        for frustum: EyeFrustum,
        projection: CameraProjection,
        flipped: Bool
    ) -> (scale: SIMD2<Float>, offset: SIMD2<Float>) {
        let mapping=projection.mapping(left:Double(frustum.left),right:Double(frustum.right),
            bottom:Double(frustum.bottom),top:Double(frustum.top),flipped:flipped)
        return (SIMD2(Float(mapping.scale.x),Float(mapping.scale.y)),
                SIMD2(Float(mapping.offset.x),Float(mapping.offset.y)))
    }

    private func makeCameraTextures(from frame: CameraFrame?, includeHands: Bool = false) -> (MTLTexture, MTLTexture)? {
        guard
            cameraPassthroughRequested || includeHands,
            let frame,
            let cache = textureCache
        else {
            return nil
        }

        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }

        func makePlane(_ index: Int, _ format: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
            let width = CVPixelBufferGetWidthOfPlane(buffer, index)
            let height = CVPixelBufferGetHeightOfPlane(buffer, index)
            var ref: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                buffer,
                nil,
                format,
                width,
                height,
                index,
                &ref
            )
            guard status == kCVReturnSuccess,
                  let ref,
                  let texture = CVMetalTextureGetTexture(ref) else {
                return nil
            }
            return (ref, texture)
        }

        guard
            let luma = makePlane(0, .r8Unorm),
            let chroma = makePlane(1, .rg8Unorm)
        else {
            return nil
        }

        // CVMetalTexture должен дожить до конца кадра.
        retainedCameraTextures.append(luma.0)
        retainedCameraTextures.append(chroma.0)
        return (luma.1, chroma.1)
    }

    private func ensureEyeTextures(for drawableSize: CGSize) {
        let budget = VRPerformanceBudget(thermalLevel: ProcessInfo.processInfo.thermalState.rawValue)
        let requested = profile.supersample.isFinite ? Double(max(profile.supersample, 1)) : 1
        let menuLimit = spatialHomeVisible ? 1.0 : 2.0
        let factor = CGFloat(min(requested, min(budget.maximumRenderScale, menuLimit)))
        // Equal integer eye widths, including after thermal resolution changes.
        let target = CGSize(
            width: max(2, (drawableSize.width * factor / 2).rounded() * 2),
            height: max(1, (drawableSize.height * factor).rounded())
        )
        if eyeTexture != nil, eyeDepthTexture != nil, eyeTextureSize == target { return }

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(target.width),
            height: Int(target.height),
            mipmapped: false
        )
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: Int(target.width),
            height: Int(target.height),
            mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private

        eyeTexture = device.makeTexture(descriptor: colorDescriptor)
        eyeDepthTexture = device.makeTexture(descriptor: depthDescriptor)
        eyeTextureSize = target
    }
}

extension MainViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "handarFeedback":
            guard let body = message.body as? [String: Any] else { return }
            if body["type"] as? String == "media-audio" {
                if (directVideoActive && message.webView === directVideoLeft) || message.webView === browser {
                    activateDirectVideoAudio()
                }
                return
            }
            guard body["type"] as? String == "click" else { return }
            playUIConfirmation()
        case "handarVideo":
            guard
                let body = message.body as? [String: Any],
                let active = body["active"] as? Bool
            else { return }
            // Когда direct video уже активирован, основной WKWebView специально
            // ставится на паузу. Его pause-событие нельзя трактовать как выход
            // из кинорежима, иначе прямой видеослой мгновенно закроется.
            if directVideoActive { return }
            setCinemaMode(active)

        case "handarApp":
            guard let body = message.body as? [String: Any],
                  let id = body["id"] as? String else { return }
            openVRApp(id: id)

        case "handarSystem":
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            handleVRSystemAction(action)

        default:
            break
        }
    }
}

// MARK: - VR desktop / VR apps ------------------------------------------------

extension MainViewController {
    private static let vrDesktopHTML = #"""
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><title>HandAR · Главный экран</title><style>:root{color-scheme:dark;--text:#fff;--muted:#ffffffa3;--glass:linear-gradient(150deg,#e1f0ff50,#8595b23b 45%,#c6abe63b);--edge:#ffffff58}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif;-webkit-user-select:none;user-select:none}
button{font:inherit;color:inherit;cursor:pointer;border:0;background:none}button:focus-visible{outline:3px solid #fff;outline-offset:5px}
button,.app{touch-action:manipulation}.hidden,[hidden]{display:none!important}
.workspace{position:relative;width:100%;height:100%;display:grid;place-items:center;background:radial-gradient(ellipse at 56% 35%,#a8d9ff16,transparent 57%),radial-gradient(ellipse at 30% 76%,#b4a1ff10,transparent 50%)}
.status{position:absolute;top:30px;left:50%;transform:translateX(-50%);display:flex;align-items:center;gap:10px;font-size:13px;font-weight:550;color:#ffffffbc;text-shadow:0 1px 8px #0008}
.status .divider{width:3px;height:3px;border-radius:50%;background:#fff6}.status #controllerState{display:none}
.glass{background:var(--glass);border:1px solid var(--edge);box-shadow:inset 0 1px 0 #ffffff2b,inset 0 -1px 0 #ffffff0a,0 12px 35px #00000029;-webkit-backdrop-filter:none;backdrop-filter:none}
.rail{position:absolute;left:10.5%;top:50%;transform:translateY(-50%);display:flex;flex-direction:column;gap:7px;padding:9px;border-radius:35px;z-index:4}
.rail button{display:grid;place-items:center;width:46px;height:46px;border-radius:50%;color:#ffffffa8;transition:.18s}.rail button.active{background:#ffffff32;color:#fff;box-shadow:inset 0 1px 1px #ffffff38}.rail svg,.control svg,.ornament svg{width:23px;height:23px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
.rail button:hover,.rail button.handar-hover,.control:hover,.control.handar-hover{background:#ffffff38;color:#fff}
.view{position:absolute;inset:90px 14% 95px 21%;display:flex;flex-direction:column;justify-content:center;align-items:center;gap:27px}
.app-page{width:100%;display:flex;flex-direction:column;align-items:center;gap:26px;animation:none}.app-row{display:flex;justify-content:center;gap:42px;width:100%}
.app{width:104px;flex-shrink:0;display:flex;flex-direction:column;align-items:center;gap:12px;border-radius:24px;padding:0;cursor:pointer}
.icon{position:relative;width:84px;height:84px;border-radius:50%;display:grid;place-items:center;background:linear-gradient(155deg,var(--a,#dedede),var(--b,#8b8b8b));box-shadow:inset 0 1px 2px #ffffff45,inset 0 -2px 4px #00000016,0 7px 13px #00000029;transition:none;isolation:isolate;overflow:hidden}
.icon:after{content:"";position:absolute;inset:0;z-index:2;pointer-events:none;border-radius:50%;box-shadow:inset 0 0 0 1px #ffffff40;background:radial-gradient(ellipse at 28% 0%,#ffffff48,transparent 62%),linear-gradient(160deg,transparent 65%,#00000008)}
.icon svg{width:48px;height:48px;fill:none;stroke:#fff;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;filter:none}.icon .solid{fill:white;stroke:none}.app span{font-size:14px;font-weight:500;letter-spacing:.05px;text-shadow:0 2px 6px #000b;white-space:nowrap}
.app:hover .icon,.app.handar-hover .icon,.app:focus-visible .icon{transform:scale(1.045);box-shadow:inset 0 1px 2px #ffffff45,0 0 0 4px #cceeff40,0 7px 22px #91caff24}.app:active .icon,.app.launch .icon{transform:scale(.94)}
.blue{--a:#66c3f2;--b:#337ce0}.red{--a:#f28e99;--b:#d34468}.pink{--a:#ff72c2;--b:#b328ee}.teal{--a:#59d1d1;--b:#03869a}.indigo{--a:#8d93ff;--b:#4e50cb}.green{--a:#9bdd9e;--b:#42aa78}.cyan{--a:#80d5e8;--b:#359dc6}.orange{--a:#ffc55b;--b:#ed7d18}.purple{--a:#c4a6ef;--b:#9067cc}.gray{--a:#d8dbe0;--b:#858b93}.dark{--a:#62666e;--b:#383e48}
.app[data-id=photos] .icon,.app[data-id=safari] .icon,.app[data-id=notes] .icon,.app[data-id=maps] .icon{background:linear-gradient(145deg,#f0f4f7,#cdd9e6)}
.app[data-id=notes] .icon svg{stroke:#a6a6a6}.app[data-id=notes] .icon:before{content:"";position:absolute;inset:0 0 65%;background:#ffd84c}
.app[data-id=maps] .icon svg{stroke:#0989ff}.app[data-id=spotify] .icon{background:linear-gradient(150deg,#dc8190,#be516e)}
.pages{height:24px;display:flex;align-items:center;gap:12px}.page-dot{width:7px;height:7px;padding:10px;position:relative;opacity:.42}.page-dot:after{content:"";position:absolute;inset:7px;border-radius:50%;background:white}.page-dot.active{opacity:1}.page-dot.handar-hover{transform:scale(1.3)}
.home-bottom{position:absolute;bottom:28px;left:50%;transform:translateX(-50%);display:flex;align-items:center;gap:14px}.control{width:44px;height:44px;border-radius:50%;display:grid;place-items:center}.grab{width:98px;height:5px;border-radius:5px;background:#ffffffb8;box-shadow:0 2px 8px #0003;pointer-events:none}
.panel{width:100%;max-width:750px;border-radius:36px;padding:32px;animation:none}.panel h1{font-size:27px;font-weight:650;letter-spacing:-.6px;margin:0 0 9px}.panel p{font-size:15px;color:var(--muted);line-height:1.5;margin:0 0 24px}.panel .tiles{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.tile{border-radius:23px;background:#ffffff15;border:1px solid #ffffff26;padding:22px 15px;text-align:left;font-weight:550;display:flex;flex-direction:column;gap:12px;min-height:130px}.tile:hover,.tile.handar-hover{background:#ffffff30}.tile svg{width:34px;height:34px;fill:none;stroke:currentColor;stroke-width:1.5}.tile small{color:var(--muted);font-size:12px;line-height:1.4;font-weight:400}
.sheet{position:absolute;right:13%;top:90px;width:340px;padding:24px;border-radius:30px;z-index:9;animation:none}.sheet-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px}.sheet h2{font-size:19px;margin:0}.sheet .row{display:flex;gap:10px;margin-top:12px}.sheet .action{background:#ffffff1d;border:1px solid #ffffff24;border-radius:18px;padding:16px;text-align:left;width:100%;font-size:14px}.sheet .action:hover,.sheet .action.handar-hover{background:#ffffff38}.sheet .small{font-size:12px;color:var(--muted);line-height:1.5}.sheet #date{font-size:13px;color:var(--muted);margin-bottom:20px}.sheet .close{background:#ffffff1a;width:30px;height:30px;border-radius:50%}.sheet #battery{margin:20px 0 10px;font-size:14px}.notice{position:absolute;bottom:78px;left:50%;transform:translateX(-50%);padding:12px 22px;border-radius:30px;font-size:14px;z-index:10}
@keyframes appear{from{opacity:0;transform:translateY(9px) scale(.98)}to{opacity:1;transform:none}}
@media(max-width:1000px){.rail{left:5%}.view{inset:65px 7% 70px 16%;gap:15px}.app-row{gap:25px}.app{width:90px;gap:9px}.icon{width:70px;height:70px}.icon svg{width:41px;height:41px}.app-page{gap:20px}.app span{font-size:12px}.status{top:18px}.sheet{right:7%;top:65px}}
@media(max-height:560px){.view{inset:48px 10% 50px 19%;gap:8px}.app-page{gap:13px}.icon{width:60px;height:60px}.icon svg{width:35px;height:35px}.app span{font-size:11px}.app{gap:6px}.status{top:12px}.home-bottom{bottom:12px}.rail{left:8%}.panel{padding:22px}.panel .tile{min-height:100px}.sheet{top:48px;max-height:calc(100% - 65px);overflow:auto}}

button.handar-hover:not(.app){outline:2px solid #ffffff50;outline-offset:2px}
.app.handar-hover .icon{outline:2px solid #ffffff70;outline-offset:3px}
button.handar-confirmed{outline:2px solid #ffffffb0;outline-offset:2px}
.app.handar-confirmed .icon{transform:scale(.97);outline:2px solid #ffffffa0;outline-offset:3px}

@media(prefers-reduced-motion:reduce){*,*:before,*:after{animation:none!important;transition:none!important}}

button.handar-hover:not(.app){outline:2px solid #ffffff50;outline-offset:2px}
.app.handar-hover .icon{outline:2px solid #ffffff70;outline-offset:3px}
button.handar-confirmed{outline:2px solid #ffffffb0;outline-offset:2px}
.app.handar-confirmed .icon{transform:scale(.97);outline:2px solid #ffffffa0;outline-offset:3px}
</style></head><body>
<main class="workspace">
<header class="status"><span id="time">--:--</span><span class="divider"></span><span>Главный экран</span><span id="controllerState"></span></header>
<nav class="rail glass" aria-label="Разделы"><button data-view="people" aria-label="Люди"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M16 5a3 3 0 0 1 0 6M18 14a5 5 0 0 1 3 5"/></svg></button><button class="active" data-view="apps" aria-label="Приложения" aria-pressed="true"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="6" cy="6" r="1.5"/><circle cx="12" cy="6" r="1.5"/><circle cx="18" cy="6" r="1.5"/><circle cx="6" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="18" cy="12" r="1.5"/><circle cx="6" cy="18" r="1.5"/><circle cx="12" cy="18" r="1.5"/><circle cx="18" cy="18" r="1.5"/></svg></button><button data-view="environments" aria-label="Окружения"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m2 19 7-12 5 8 3-5 5 9ZM7 10l2 2 2-2"/><circle cx="17" cy="5" r="2"/></svg></button></nav>
<section class="view" id="apps" aria-label="Приложения"><div class="app-page" data-page="0"><div class="app-row"><button class="app" data-id="cinema" aria-label="Кино"><div class="icon teal"><svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 5v14M17 5v14M3 9h4M3 15h4M17 9h4M17 15h4"/></svg></div><span>Кино</span></button><button class="app" data-id="spotify" aria-label="Музыка"><div class="icon red"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 17V6l9-2v11M10 8l9-2"/><ellipse cx="7" cy="17" rx="3" ry="2.3" fill="white" stroke="none"/><ellipse cx="16" cy="15" rx="3" ry="2.3" fill="white" stroke="none"/></svg></div><span>Музыка</span></button><button class="app" data-id="safari" aria-label="Safari"><div class="icon blue"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="#36a8f5" stroke="#b9e8ff"/><g stroke="#fff" stroke-width=".6"><path d="M12 3v1.6" transform="rotate(0 12 12)"/><path d="M12 3v1.6" transform="rotate(30 12 12)"/><path d="M12 3v1.6" transform="rotate(60 12 12)"/><path d="M12 3v1.6" transform="rotate(90 12 12)"/><path d="M12 3v1.6" transform="rotate(120 12 12)"/><path d="M12 3v1.6" transform="rotate(150 12 12)"/><path d="M12 3v1.6" transform="rotate(180 12 12)"/><path d="M12 3v1.6" transform="rotate(210 12 12)"/><path d="M12 3v1.6" transform="rotate(240 12 12)"/><path d="M12 3v1.6" transform="rotate(270 12 12)"/><path d="M12 3v1.6" transform="rotate(300 12 12)"/><path d="M12 3v1.6" transform="rotate(330 12 12)"/></g><path d="m16 7-3 6-2-2Z" fill="#ff5263" stroke="none"/><path d="m8 17 3-6 2 2Z" fill="white" stroke="none"/></svg></div><span>Safari</span></button><button class="app" data-id="photos" aria-label="Фото"><div class="icon pink"><svg viewBox="0 0 24 24" aria-hidden="true"><ellipse cx="12" cy="7" rx="3.4" ry="5.2" fill="#ffb92e" opacity=".82" transform="rotate(0 12 12)" stroke="none"/><ellipse cx="12" cy="7" rx="3.4" ry="5.2" fill="#ff7b28" opacity=".82" transform="rotate(45 12 12)" stroke="none"/><ellipse cx="12" cy="7" rx="3.4" ry="5.2" fill="#fc4267" opacity=".82" transform="rotate(90 12 12)" stroke="none"/><ellipse cx="12" cy="7" rx="3.4" ry="5.2" fill="#d758bb" opacity=".82" transform="rotate(135 12 12)" stroke="none"/><ellipse cx="12" cy="7" rx="3.4" ry="5.2" fill="#7c75d7" opacity=".82" transform="rotate(180 12 12)" stroke="none"/><ellipse cx="12" cy="7" rx="3.4" ry="5.2" fill="#49a3eb" opacity=".82" transform="rotate(225 12 12)" stroke="none"/><ellipse cx="12" cy="7" rx="3.4" ry="5.2" fill="#57c990" opacity=".82" transform="rotate(270 12 12)" stroke="none"/><ellipse cx="12" cy="7" rx="3.4" ry="5.2" fill="#c2d94c" opacity=".82" transform="rotate(315 12 12)" stroke="none"/></svg></div><span>Фото</span></button></div><div class="app-row"><button class="app" data-id="gmail" aria-label="Почта"><div class="icon red"><svg viewBox="0 0 24 24"><path d="M4 6h16v12H4z"/><path d="m4 7 8 6 8-6"/></svg></div><span>Почта</span></button><button class="app" data-id="messages" aria-label="Сообщения"><div class="icon green"><svg viewBox="0 0 24 24"><path d="M4 5h16v11H9l-5 4z"/></svg></div><span>Сообщения</span></button><button class="app" data-id="maps" aria-label="Карты"><div class="icon orange"><svg viewBox="0 0 24 24"><path d="M12 20s6-6 6-10a6 6 0 1 0-12 0c0 4 6 10 6 10Z"/><circle cx="12" cy="10" r="2"/></svg></div><span>Карты</span></button><button class="app" data-id="notes" aria-label="Заметки"><div class="icon orange"><svg viewBox="0 0 24 24"><path d="M6 4h12v16H6z"/><path d="M9 8h6M9 12h6M9 16h4"/></svg></div><span>Заметки</span></button><button class="app" data-id="settings" aria-label="Настройки"><div class="icon gray"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 0 0-2-1.1L14.3 3h-4.6l-.4 2.7a7 7 0 0 0-2 1.1L5 5.9 3 9.3l2 1.5A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 0 0 2 1.1l.4 2.7h4.6l.4-2.7a7 7 0 0 0 2-1.1l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2Z"/></svg></div><span>Настройки</span></button></div><div class="app-row"><button class="app" data-id="files" aria-label="Файлы"><div class="icon blue"><svg viewBox="0 0 24 24"><path d="M4 7h6l2 2h8v9H4z"/><path d="M4 10h16"/></svg></div><span>Файлы</span></button><button class="app" data-id="telegram" aria-label="Telegram"><div class="icon cyan"><svg viewBox="0 0 24 24"><path class="solid" d="M20.8 4.4 3.2 11.2c-1 .4-1 1.1-.2 1.4l4.5 1.4 1.7 5.1c.2.6.1.9.8.9.5 0 .8-.2 1.1-.5l2.1-2 4.4 3.3c.8.4 1.4.2 1.6-.7l3.1-14.4c.3-1.2-.5-1.8-1.5-1.3Z"/></svg></div><span>Telegram</span></button><button class="app" data-id="games" aria-label="Игры"><div class="icon purple"><svg viewBox="0 0 24 24"><rect x="4" y="7" width="16" height="11" rx="3"/><path d="M8 12h4M10 10v4"/><circle cx="16" cy="11.5" r="1" fill="#fff" stroke="none"/><circle cx="18" cy="14.5" r="1" fill="#fff" stroke="none"/></svg></div><span>Игры</span></button><button class="app" data-id="calculator" aria-label="Калькулятор"><div class="icon dark"><svg viewBox="0 0 24 24"><rect x="5" y="3" width="14" height="18" rx="2"/><path d="M8 7h8M8 11h2M12 11h2M16 11h0M8 15h2M12 15h2M8 18h8"/></svg></div><span>Калькулятор</span></button></div></div><div class="app-page" data-page="1" hidden><div class="app-row"><button class="app" data-id="youtube" aria-label="YouTube"><div class="icon red"><svg viewBox="0 0 24 24"><path class="solid" d="M21 7.4a2.8 2.8 0 0 0-2-2C17.2 5 12 5 12 5s-5.2 0-7 .4a2.8 2.8 0 0 0-2 2A29 29 0 0 0 2.6 12 29 29 0 0 0 3 16.6a2.8 2.8 0 0 0 2 2c1.8.4 7 .4 7 .4s5.2 0 7-.4a2.8 2.8 0 0 0 2-2 29 29 0 0 0 .4-4.6A29 29 0 0 0 21 7.4Z"/><path d="m10 9 5 3-5 3z" fill="#e21c2a" stroke="none"/></svg></div><span>YouTube</span></button><button class="app" data-id="tiktok" aria-label="TikTok"><div class="icon dark"><svg viewBox="0 0 24 24"><path d="M14 5v9a4 4 0 1 1-3.2-3.9"/><path d="M14 5c1.2 2.2 2.8 3.4 5 3.6"/></svg></div><span>TikTok</span></button><button class="app" data-id="discord" aria-label="Discord"><div class="icon indigo"><svg viewBox="0 0 24 24"><path d="M7 7.8c2.9-1.1 7.1-1.1 10 0 1.5 1.3 2.3 4.6 1.9 7.6-1.9 1.3-3.7 2-5.5 2.4l-.8-1.1"/><path d="M7 7.8c-1.5 1.3-2.3 4.6-1.9 7.6 1.9 1.3 3.7 2 5.5 2.4l.8-1.1"/><circle cx="9.2" cy="12.5" r="1"/><circle cx="14.8" cy="12.5" r="1"/></svg></div><span>Discord</span></button><button class="app" data-id="google" aria-label="Google"><div class="icon dark"><svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.2-5.5"/><path d="M20 7v5h-5"/></svg></div><span>Google</span></button></div><div class="app-row"><button class="app" data-id="wikipedia" aria-label="Wikipedia"><div class="icon gray"><svg viewBox="0 0 24 24"><path d="M4 6h4l4 10 4-10h4"/><path d="M9 18h6"/></svg></div><span>Wikipedia</span></button><button class="app" data-id="reddit" aria-label="Reddit"><div class="icon orange"><svg viewBox="0 0 24 24"><circle cx="12" cy="13" r="6.5"/><circle cx="9.5" cy="12.5" r=".9" fill="#fff" stroke="none"/><circle cx="14.5" cy="12.5" r=".9" fill="#fff" stroke="none"/><path d="M9 15c1.7 1.2 4.3 1.2 6 0"/><path d="m14.5 6 1.8-2.2"/><circle cx="17.2" cy="3.5" r="1"/></svg></div><span>Reddit</span></button><button class="app" data-id="travel" aria-label="Путешествия"><div class="icon cyan"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/></svg></div><span>Путешествия</span></button><button class="app" data-id="graffiti" aria-label="Граффити"><div class="icon purple"><svg viewBox="0 0 24 24"><rect x="7" y="8" width="10" height="13" rx="2"/><path d="M9 8V5h6v3M11 5V2h4M18 4h3M19 7l2 1"/></svg></div><span>Граффити</span></button><button class="app" data-id="phone" aria-label="Телефон"><div class="icon green"><svg viewBox="0 0 24 24"><path d="M7 4c1.1 0 2 .9 2 2 0 1-.2 1.8-.6 2.6-.2.4-.1.8.2 1.1l2.1 2.1c.3.3.7.4 1.1.2.8-.4 1.6-.6 2.6-.6 1.1 0 2 .9 2 2v3c0 1.1-.9 2-2 2C9.8 18.4 5.6 14.2 4.6 9.1 4.4 8.1 5.2 7 6.3 6.7z"/></svg></div><span>Телефон</span></button></div></div><div class="pages" aria-label="Страницы"><button class="page-dot active" data-show-page="0" aria-label="Первая страница" aria-pressed="true"></button><button class="page-dot" data-show-page="1" aria-label="Вторая страница" aria-pressed="false"></button></div></section>
<section class="view" id="people" hidden><div class="panel glass"><h1>Люди</h1><p>Выбери, где продолжить общение.</p><div class="tiles"><button class="tile" data-id="telegram"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M16 5a3 3 0 0 1 0 6M18 14a5 5 0 0 1 3 5"/></svg>Telegram<small>Открыть веб-приложение</small></button><button class="tile" data-id="discord"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M16 5a3 3 0 0 1 0 6M18 14a5 5 0 0 1 3 5"/></svg>Discord<small>Открыть веб-приложение</small></button><button class="tile" data-id="messages"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0 1 12 0v2M16 5a3 3 0 0 1 0 6M18 14a5 5 0 0 1 3 5"/></svg>Сообщения<small>Локальный интерфейс HandAR</small></button></div></div></section>
<section class="view" id="environments" hidden><div class="panel glass"><h1>Окружения</h1><p>Переключай пространство вокруг своих приложений.</p><div class="tiles"><button class="tile" data-system="environment-camera"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2" y="6" width="20" height="14" rx="4"/><circle cx="12" cy="13" r="4"/><path d="m8 6 2-3h4l2 3"/></svg>Твоё пространство<small>Сквозное видео с камеры</small></button><button class="tile" data-system="environment-dark"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 15A9 9 0 0 1 9 3a9 9 0 1 0 11 12Z"/></svg>Тёмное пространство<small>Спокойный фон без камеры</small></button><button class="tile" data-id="cinema"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m2 19 7-12 5 8 3-5 5 9ZM7 10l2 2 2-2"/><circle cx="17" cy="5" r="2"/></svg>Кинотеатр<small>Объёмный зал HandAR</small></button></div></div></section>
<div class="home-bottom"><div class="grab"></div><button class="control glass" id="control-toggle" aria-label="Пункт управления" aria-expanded="false"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 5h14M5 12h14M5 19h14"/><circle cx="9" cy="5" r="2" fill="#aaa"/><circle cx="15" cy="12" r="2" fill="#aaa"/><circle cx="9" cy="19" r="2" fill="#aaa"/></svg></button></div>
<aside class="sheet glass" id="control-center" aria-label="Пункт управления" hidden><div class="sheet-head"><h2>Пункт управления</h2><button class="close" id="control-close" aria-label="Закрыть">×</button></div><div id="date"></div><div class="row"><button class="action" data-system="center">Центрировать окно</button><button class="action" data-id="settings">Настройки</button></div><div class="row"><button class="action" data-system="environment-camera">Камера</button><button class="action" data-system="environment-dark">Тёмный фон</button></div><div id="battery">Батарея —</div><div class="row"><button class="action" data-system="controller-diagnostics">Проверить VR BOX</button></div><div class="row"><button class="action" data-system="exit">Выйти из VR</button></div></aside>
<div class="notice glass" id="notice" role="status" hidden></div>
</main><script>
function post(id){try{window.webkit.messageHandlers.handarApp.postMessage({id:id});}catch(e){}}
function system(action){try{window.webkit.messageHandlers.handarSystem.postMessage({action:action});}catch(e){}}
function showView(id){document.querySelectorAll('.view').forEach(v=>v.hidden=v.id!==id);document.querySelectorAll('[data-view]').forEach(b=>{b.classList.toggle('active',b.dataset.view===id);b.setAttribute('aria-pressed',String(b.dataset.view===id))});closeControl();}
function showPage(page){document.querySelectorAll('[data-page]').forEach(p=>p.hidden=Number(p.dataset.page)!==page);document.querySelectorAll('[data-show-page]').forEach(b=>{b.classList.toggle('active',Number(b.dataset.showPage)===page);b.setAttribute('aria-pressed',String(Number(b.dataset.showPage)===page))});}
window.__handarSwipePage=function(direction){
  const apps=document.getElementById('apps'),controls=document.getElementById('control-center');
  if(!apps||apps.hidden||(controls&&!controls.hidden)||document.hidden)return false;
  const pages=Array.from(apps.querySelectorAll('[data-page]')),current=pages.findIndex(p=>!p.hidden);
  const next=Math.max(0,Math.min(pages.length-1,current+(direction<0?1:-1)));
  if(next===current||current<0)return false;
  showPage(Number(pages[next].dataset.page));return true;
};
function closeControl(){document.getElementById('control-center').hidden=true;document.getElementById('control-toggle').setAttribute('aria-expanded','false');}
document.getElementById('control-toggle').onclick=()=>{const p=document.getElementById('control-center');p.hidden=!p.hidden;document.getElementById('control-toggle').setAttribute('aria-expanded',String(!p.hidden));};
document.getElementById('control-close').onclick=closeControl;
document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>showView(b.dataset.view));
document.querySelectorAll('[data-show-page]').forEach(b=>b.onclick=()=>showPage(Number(b.dataset.showPage)));
document.querySelectorAll('[data-id]').forEach(b=>b.onclick=()=>{b.classList.add('launch');post(b.dataset.id);setTimeout(()=>b.classList.remove('launch'),250);});
document.querySelectorAll('[data-system]').forEach(b=>b.onclick=()=>{system(b.dataset.system);if(b.dataset.system.startsWith('environment-')){const n=document.getElementById('notice');n.textContent=b.dataset.system==='environment-camera'?'Сквозное видео включено':'Тёмное пространство';n.hidden=false;clearTimeout(window.noticeTimer);window.noticeTimer=setTimeout(()=>n.hidden=true,2200);}});
function clock(){const d=new Date();document.getElementById('time').textContent=d.toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit'});document.getElementById('date').textContent=d.toLocaleDateString('ru-RU',{weekday:'long',day:'numeric',month:'long'});}clock();setInterval(clock,1000);
document.addEventListener('keydown',e=>{if(e.key==='Escape'){closeControl();showView('apps');}if(e.key==='ArrowRight')showPage(1);if(e.key==='ArrowLeft')showPage(0);});
</script></body></html>
"""#

    private static func htmlPage(title: String, icon: String, accent: String, body: String, scripts: String = "") -> String {
        let template = #"""
<!doctype html><html lang="ru"><head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta charset="utf-8"><title>HandAR VR App</title>
<style>
:root{--accent:%ACCENT%}
*{box-sizing:border-box}html,body{margin:0;width:100%%;height:100%%;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Helvetica Neue",Arial,sans-serif;background:linear-gradient(135deg,#0d1118,#1a2030);color:#fff}body:before{content:"";position:fixed;inset:0;background:radial-gradient(circle at 70%% 20%%,var(--accent),transparent 42%%);opacity:.28}.wrap{position:relative;height:100%%;padding:22px 34px;display:flex;flex-direction:column;gap:18px}.top{height:44px;display:flex;align-items:center;justify-content:space-between}.brand{display:flex;align-items:center;gap:12px}.back{border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.1);color:#fff;border-radius:15px;padding:10px 15px;font-size:15px}.title{font-size:22px;font-weight:700}.card{flex:1;border:1px solid rgba(255,255,255,.15);background:rgba(255,255,255,.07);backdrop-filter:blur(25px);border-radius:28px;padding:26px;overflow:auto}.hero{display:flex;align-items:center;gap:18px}.bigicon{width:74px;height:74px;border-radius:22px;background:var(--accent);display:flex;align-items:center;justify-content:center;font-size:34px;box-shadow:0 10px 30px rgba(0,0,0,.24)}h1{margin:0;font-size:32px}p{color:rgba(255,255,255,.7);line-height:1.45}.row{display:flex;gap:12px;flex-wrap:wrap}.btn{border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.12);color:#fff;border-radius:17px;padding:13px 18px;font-size:15px}.btn.primary{background:var(--accent);border-color:transparent}.small{font-size:12px;color:rgba(255,255,255,.48)}textarea{width:100%%;height:58%%;resize:none;border:1px solid rgba(255,255,255,.18);background:rgba(0,0,0,.2);color:#fff;border-radius:18px;padding:16px;font:inherit;outline:none}.display{font-size:48px;text-align:right;padding:18px;background:rgba(0,0,0,.25);border-radius:20px;margin-bottom:14px}.keys{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}.key{padding:20px 10px;border:0;border-radius:16px;background:rgba(255,255,255,.1);color:#fff;font-size:22px}.key.op{background:var(--accent)}.photo-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:22px}.photo{aspect-ratio:1.25;border-radius:22px;display:flex;align-items:flex-end;padding:14px;font-weight:700;background:linear-gradient(145deg,var(--accent),rgba(255,255,255,.1)),radial-gradient(circle at 70% 25%,#fff5,transparent 35%);border:1px solid rgba(255,255,255,.14)}.p2{filter:saturate(.75)}.p3{filter:hue-rotate(28deg)}.p4{filter:hue-rotate(90deg)}.p5{filter:hue-rotate(145deg)}.p6{filter:hue-rotate(220deg)}.file-list,.chat-list{display:flex;flex-direction:column;gap:10px;margin-top:24px}.file-row,.chat{border:1px solid rgba(255,255,255,.13);background:rgba(255,255,255,.06);color:#fff;border-radius:18px;padding:15px 17px;text-align:left}.file-row{display:grid;grid-template-columns:34px 1fr;gap:3px 10px}.file-row span{grid-row:1/3;font-size:22px}.file-row small{color:rgba(255,255,255,.48)}.chat{display:grid;grid-template-columns:1fr auto;gap:4px 12px}.chat span{color:rgba(255,255,255,.68)}.chat time{grid-column:2;grid-row:1/3;color:rgba(255,255,255,.38);font-size:12px}.phone-display{font-size:36px;letter-spacing:2px;text-align:center;padding:18px;border-radius:18px;background:rgba(0,0,0,.22);margin:22px 0 14px}.phone-keys{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
html,body{background:transparent!important;color:#fff;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif}
body:before{display:none}.wrap{padding:28px 38px 75px 148px;gap:0;position:relative}
.top{height:64px;flex-shrink:0;padding:0 25px;background:linear-gradient(130deg,#bcbcbc65,#64646475);border:1px solid #ffffff40;border-bottom:0;border-radius:28px 28px 0 0;backdrop-filter:blur(30px);-webkit-backdrop-filter:blur(30px)}
.title{font-size:21px;font-weight:650;letter-spacing:-.4px}.brand{gap:14px}.back{border:0;background:#ffffff1d;border-radius:50%;width:35px;height:35px;padding:0;font-size:0}.back:before{content:"‹";font-size:30px;line-height:30px}.top>.small{font-size:12px;color:#ffffff80}
.card{border-radius:0 0 28px 28px;border-top:0;padding:28px;background:linear-gradient(135deg,#87878780,#4242429c);border-color:#ffffff36;backdrop-filter:blur(35px) saturate(110%);-webkit-backdrop-filter:blur(35px) saturate(110%);box-shadow:0 18px 45px #0002;scrollbar-width:thin}
h1{font-size:28px;font-weight:650;letter-spacing:-.6px}.hero{gap:16px}.hero p{font-size:14px}.bigicon{width:58px;height:58px;border-radius:50%;font-size:27px;box-shadow:inset 0 1px 2px #fff5,0 6px 12px #0002}
.btn,.key,.file-row,.chat{border-color:#ffffff27;background:#ffffff17;border-radius:18px;box-shadow:inset 0 1px 0 #ffffff10}.btn{border-radius:30px;padding:12px 22px}.btn.primary{background:#ffffffdf;color:#202020;font-weight:600}.btn:hover,.key:hover,.file-row:hover,.handar-hover{background:#ffffff35}.btn.primary:hover{background:#fff}.key.op{background:#ffffff45}.key{padding:15px 10px}.display{background:#00000015;font-weight:300}.file-row,.chat{padding:17px}.photo{border-radius:20px}textarea{border-radius:20px;background:#00000012;border-color:#ffffff25}.small{color:#ffffff90}p{color:#ffffffb5}
.spatial-sidebar{position:absolute;top:50%;left:34px;transform:translateY(-50%);display:flex;flex-direction:column;gap:8px;padding:9px;background:linear-gradient(145deg,#d1d1d14d,#67676766);border:1px solid #ffffff40;border-radius:34px;backdrop-filter:blur(25px);-webkit-backdrop-filter:blur(25px)}
.spatial-sidebar button{width:47px;height:47px;display:grid;place-items:center;color:#fff;background:transparent;border:0;border-radius:50%;cursor:pointer}.spatial-sidebar button:hover,.spatial-sidebar button.handar-hover{background:#ffffff38}.spatial-sidebar svg{width:23px;height:23px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
.window-ornament{position:absolute;bottom:15px;left:calc(50% + 55px);transform:translateX(-50%);display:flex;gap:5px;align-items:center;padding:7px;background:linear-gradient(145deg,#c5c5c54f,#60606075);border:1px solid #ffffff40;border-radius:35px;box-shadow:0 8px 25px #0002;backdrop-filter:blur(25px);-webkit-backdrop-filter:blur(25px)}.window-ornament button{padding:9px 18px;border-radius:22px;background:none;color:#fff;border:0;font:inherit;font-size:13px;cursor:pointer}.window-ornament button:hover,.window-ornament button.handar-hover{background:#ffffff2b}.window-ornament .separator{width:1px;height:20px;background:#ffffff30}
button:focus-visible,a:focus-visible{outline:2px solid white;outline-offset:3px}button{touch-action:manipulation}
@media(max-height:560px){.wrap{padding:14px 22px 65px 115px}.spatial-sidebar{left:22px}.top{height:54px}.card{padding:20px}.hero p{margin:8px 0 16px}.window-ornament{bottom:10px}}


button.handar-hover:not(.app){outline:2px solid #ffffff50;outline-offset:2px}
.app.handar-hover .icon{outline:2px solid #ffffff70;outline-offset:3px}
button.handar-confirmed{outline:2px solid #ffffffb0;outline-offset:2px}
.app.handar-confirmed .icon{transform:scale(.97);outline:2px solid #ffffffa0;outline-offset:3px}
</style></head><body><div class="wrap"><nav class="spatial-sidebar" aria-label="Навигация"><button onclick="post('home')" aria-label="Главный экран"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="6" cy="6" r="1.5"/><circle cx="12" cy="6" r="1.5"/><circle cx="18" cy="6" r="1.5"/><circle cx="6" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="18" cy="12" r="1.5"/><circle cx="6" cy="18" r="1.5"/><circle cx="12" cy="18" r="1.5"/><circle cx="18" cy="18" r="1.5"/></svg></button><button onclick="post('safari')" aria-label="Safari"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m3 11 9-8 9 8M5 10v10h5v-6h4v6h5V10"/></svg></button><button onclick="post('photos')" aria-label="Фото"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2" y="6" width="20" height="14" rx="4"/><circle cx="12" cy="13" r="4"/><path d="m8 6 2-3h4l2 3"/></svg></button><button onclick="post('settings')" aria-label="Настройки"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 5h14M5 12h14M5 19h14"/><circle cx="9" cy="5" r="2" fill="#aaa"/><circle cx="15" cy="12" r="2" fill="#aaa"/><circle cx="9" cy="19" r="2" fill="#aaa"/></svg></button></nav>
<div class="top"><div class="brand"><button class="back" aria-label="Главный экран" onclick="post('home')"></button><div class="title">%TITLE%</div></div><div class="small">HandAR</div></div>
<div class="card">%BODY%</div><div class="window-ornament" aria-label="Панель окна"><button onclick="post('home')">Приложения</button><span class="separator"></span><button onclick="sys('center')">Центрировать</button><button onclick="post('settings')">Настройки</button></div></div>
<script>function sys(action){try{window.webkit.messageHandlers.handarSystem.postMessage({action:action});}catch(e){}}function post(id){try{window.webkit.messageHandlers.handarApp.postMessage({id:id});}catch(e){}}%SCRIPTS%</script>
</body></html>
"""#
        return template
            .replacingOccurrences(of: "%ACCENT%", with: accent)
            .replacingOccurrences(of: "%TITLE%", with: title)
            .replacingOccurrences(of: "%BODY%", with: body)
            .replacingOccurrences(of: "%SCRIPTS%", with: scripts)
            .replacingOccurrences(of: "%%", with: "%")
    }

    private static let vrTravelHTML = htmlPage(
        title: "Путешествия · 360°", icon: "🌐", accent: "#65cce3",
        body: """
<div class="hero"><div class="bigicon">🌐</div><div><h1>Оглянись вокруг</h1><p>Настоящие фотопанорамы. Сохранены в приложении и работают без интернета.</p></div></div>
<div class="row"><button class="btn primary" onclick="post('panorama-burj')">Бурдж-Халифа · ночь · 360°</button></div>
<p>Вид у Dubai Mall. Поворачивай голову, чтобы осмотреться. Кнопки «Места» и «Вперёд» находятся чуть ниже взгляда. Работают удержание, щипок и режим отдыха рук.</p>
<p class="small">Фото: Levon Avagyan · CC BY-SA 3.0 · оригинал без изменений. Ночная съёмка со швами склейки. Обзор с одной точки, без перемещения по улице.</p>
<p class="small"><a href="https://commons.wikimedia.org/wiki/File:Dubai_Mall_-_panoramio_(1).jpg">Источник фотографии</a> · <a href="https://creativecommons.org/licenses/by-sa/3.0/">Условия лицензии</a></p>
<p><b>Бакинский бульвар</b> — пока недоступен: свободный оригинал полной панорамы 360° не найден.</p>
"""
    )

    private static let vrNotesHTML = htmlPage(
        title: "Заметки",
        icon: "✎",
        accent: "#f59e0b",
        body: """
<div class="hero"><div class="bigicon">✎</div><div><h1>Заметки</h1><p>Локальная VR-заметка сохраняется на этом устройстве внутри WebView.</p></div></div>
<textarea id="note" placeholder="Напиши здесь..."></textarea>
<div class="row"><button class="btn primary" id="save">Сохранить</button><button class="btn" id="clear">Очистить</button></div>
""",
        scripts: """
const note=document.getElementById('note');note.value=localStorage.getItem('handar-note')||'';
document.getElementById('save').onclick=()=>localStorage.setItem('handar-note',note.value);
document.getElementById('clear').onclick=()=>{note.value='';localStorage.removeItem('handar-note');};
"""
    )

    private static let vrCalculatorHTML = htmlPage(
        title: "Калькулятор",
        icon: "＋",
        accent: "#4b5563",
        body: """
<div class="display" id="display">0</div><div class="keys">
<button class="key" data-k="7">7</button><button class="key" data-k="8">8</button><button class="key" data-k="9">9</button><button class="key op" data-k="/">÷</button>
<button class="key" data-k="4">4</button><button class="key" data-k="5">5</button><button class="key" data-k="6">6</button><button class="key op" data-k="*">×</button>
<button class="key" data-k="1">1</button><button class="key" data-k="2">2</button><button class="key" data-k="3">3</button><button class="key op" data-k="-">−</button>
<button class="key" data-k="0">0</button><button class="key" data-k=".">.</button><button class="key op" data-k="=">=</button><button class="key op" data-k="+">+</button>
</div><div class="row" style="margin-top:14px"><button class="btn" id="clear">Сбросить</button></div>
""",
        scripts: """
let expr='';const d=document.getElementById('display');function render(){d.textContent=expr||'0'}
document.querySelectorAll('[data-k]').forEach(b=>b.onclick=()=>{const k=b.dataset.k;if(k==='='){try{expr=String(Function('return '+expr)())}catch(e){expr='Ошибка'}}else{expr+=k}render()});document.getElementById('clear').onclick=()=>{expr='';render()};
"""
    )

    private static let vrPhotosHTML = htmlPage(
        title: "Фото",
        icon: "▦",
        accent: "#d946ef",
        body: """
<div class="hero"><div class="bigicon">▦</div><div><h1>Фото</h1><p>VR-галерея HandAR. Здесь можно пролистывать локальные снимки без выхода из VR.</p></div></div>
<div class="photo-grid">
<div class="photo p1">Закат</div><div class="photo p2">Горы</div><div class="photo p3">Город</div><div class="photo p4">Море</div><div class="photo p5">Путешествие</div><div class="photo p6">Избранное</div>
</div>
""",
        scripts: """
// Фото в этой демо-версии намеренно локальные UI-заглушки: системную библиотеку iOS нельзя встроить внутрь стороннего WKWebView.
"""
    )

    private static let vrFilesHTML = htmlPage(
        title: "Файлы",
        icon: "▰",
        accent: "#3b82f6",
        body: """
<div class="hero"><div class="bigicon">▰</div><div><h1>Файлы</h1><p>VR-файловый менеджер HandAR с виртуальными папками для контента шлема.</p></div></div>
<div class="file-list">
<button class="file-row"><span>▱</span><b>На iPhone</b><small>Локальные данные приложения</small></button>
<button class="file-row"><span>▱</span><b>VR Downloads</b><small>Загруженные веб-файлы</small></button>
<button class="file-row"><span>▱</span><b>Избранное</b><small>Быстрый доступ</small></button>
</div>
"""
    )

    private static let vrMessagesHTML = htmlPage(
        title: "Сообщения",
        icon: "☏",
        accent: "#22c55e",
        body: """
<div class="hero"><div class="bigicon">☏</div><div><h1>Сообщения</h1><p>Внутренний VR-интерфейс чатов. Это не системное приложение Messages.</p></div></div>
<div class="chat-list">
<div class="chat"><b>HandAR</b><span>Добро пожаловать в VR Desktop</span><time>сейчас</time></div>
<div class="chat"><b>VR Friends</b><span>Новый сеанс готов</span><time>сегодня</time></div>
<div class="chat"><b>Заметки</b><span>Проверь настройки линз</span><time>вчера</time></div>
</div>
"""
    )

    private static let vrPhoneHTML = htmlPage(
        title: "Телефон",
        icon: "☎",
        accent: "#22c55e",
        body: """
<div class="hero"><div class="bigicon">☎</div><div><h1>Телефон</h1><p>VR-набор номера. Звонок через системное приложение здесь не встраивается.</p></div></div>
<div class="phone-display" id="phone-display">⌕</div>
<div class="phone-keys">
<button class="key" data-k="1">1</button><button class="key" data-k="2">2</button><button class="key" data-k="3">3</button>
<button class="key" data-k="4">4</button><button class="key" data-k="5">5</button><button class="key" data-k="6">6</button>
<button class="key" data-k="7">7</button><button class="key" data-k="8">8</button><button class="key" data-k="9">9</button>
<button class="key" data-k="*">*</button><button class="key" data-k="0">0</button><button class="key" data-k="#">#</button>
</div>
""",
        scripts: """
let number='';const pd=document.getElementById('phone-display');document.querySelectorAll('[data-k]').forEach(b=>b.onclick=()=>{number+=b.dataset.k;pd.textContent=number;});
"""
    )

    private static let vrGamesHTML = htmlPage(
        title: "Игры",
        icon: "🎮",
        accent: "#7c3aed",
        body: """
<style>
body{background:#05060b}
#arcade{position:relative;height:calc(100vh - 106px);min-height:430px;border-radius:28px;overflow:hidden;border:1px solid rgba(255,255,255,.13);background:radial-gradient(circle at 50% 20%,rgba(124,58,237,.18),transparent 36%),linear-gradient(180deg,#0c1019,#04050a)}
.screen{position:absolute;inset:0;display:none;padding:22px}.screen.active{display:block}
.gamebar{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:16px}.gamebar h2{margin:0;font-size:26px}.gamebar .score{font-size:18px;font-weight:800}.gamecardgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;height:calc(100% - 62px)}
.gamecard{border:1px solid rgba(255,255,255,.13);border-radius:25px;background:linear-gradient(160deg,rgba(255,255,255,.10),rgba(255,255,255,.035));color:#fff;text-align:left;padding:22px;cursor:pointer;box-shadow:0 18px 45px rgba(0,0,0,.2);display:flex;flex-direction:column;justify-content:space-between}.gamecard:active{transform:scale(.985)}
.gameemoji{font-size:55px}.gamecard h3{font-size:23px;margin:12px 0 6px}.gamecard p{font-size:14px;line-height:1.4;color:rgba(255,255,255,.68);margin:0}.tag{display:inline-flex;margin-top:14px;padding:7px 10px;border-radius:999px;background:rgba(255,255,255,.09);font-size:12px;color:rgba(255,255,255,.72)}
#fruitCanvas,#neonCanvas,#stackCanvas{position:absolute;inset:0;width:100%;height:100%;touch-action:none}.arena{position:absolute;inset:82px 0 0;border-radius:18px;overflow:hidden}.hud{position:absolute;left:22px;right:22px;top:18px;display:flex;justify-content:space-between;z-index:3;font-size:19px;font-weight:800;pointer-events:none;text-shadow:0 3px 16px #000}.help{position:absolute;left:0;right:0;bottom:14px;text-align:center;color:rgba(255,255,255,.56);font-size:12px;z-index:3;pointer-events:none}.gamebtn{border:1px solid rgba(255,255,255,.16);background:rgba(255,255,255,.09);color:#fff;border-radius:14px;padding:10px 14px}.gamebtn.primary{background:#7c3aed;border-color:#7c3aed}
#gameOverlay{position:absolute;inset:0;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.58);z-index:8;text-align:center}.overlayBox{padding:30px 38px;border-radius:24px;background:rgba(15,18,27,.93);border:1px solid rgba(255,255,255,.14)}.overlayBox h2{margin:0 0 8px;font-size:32px}.overlayBox p{margin:0 0 18px}
@media(max-width:900px){.gamecardgrid{grid-template-columns:1fr}.gamecard{min-height:135px}.gamecardgrid{overflow:auto}}
</style>
<div id="arcade">
  <section id="homeScreen" class="screen active">
    <div class="gamebar"><h2>VR Arcade</h2><button class="gamebtn" onclick="post('home')">Рабочий стол</button></div>
    <div class="gamecardgrid">
      <div class="gamecard" onclick="startFruit()"><div><div class="gameemoji">🍉🍓</div><h3>Fruit Slice VR</h3><p>Твоя версия игры с нарезкой фруктов. Двигай рукой и режь летящие фрукты, избегая бомб.</p><span class="tag">Рука + pinch</span></div><div>▶ Играть</div></div>
      <div class="gamecard" onclick="startNeon()"><div><div class="gameemoji">☄️✨</div><h3>Neon Dodge</h3><p>Держи указатель подальше от метеоров и продержись 30 секунд, собирая очки.</p><span class="tag">Рука + движение</span></div><div>▶ Играть</div></div>
      <div class="gamecard" onclick="startStack()"><div><div class="gameemoji">🧱🏗️</div><h3>Stack Rush</h3><p>Точно ставь движущиеся блоки друг на друга и строй башню как можно выше.</p><span class="tag">Рука + pinch</span></div><div>▶ Играть</div></div>
      <div class=\"gamecard\" onclick=\"post('time-motion-game')\"><div><div class=\"gameemoji\">🔫⏱️</div><h3>Time Motion</h3><p>Замедление времени: почти неподвижный мир, движение ускоряет его. Возьми пистолет кулаком — он стреляет сам, укрывайся за ящиками и уворачивайся головой от красных врагов. Три волны, очки и локальный рекорд.</p><span class=\"tag\">Рука · Пистолет · Замедление · Рекорд</span></div><div>▶ Играть</div></div>
      <div class="gamecard" onclick="post('security-game')"><div><div class="gameemoji">🔦🪪</div><h3>Security VR</h3><p>Охрана клуба: сканер и алкотестер работают наведением. Каждые 5 решений меняются правила смены. Собирай серии правильных решений, улучшай точность и личный рекорд. Есть пауза, захват гостей и предметов.</p><span class="tag">Смены · Серии · Рекорд · Управление наведением</span></div><div>▶ Играть</div></div>
    </div>
  </section>
  <section id="fruitScreen" class="screen"><div class="gamebar"><h2>Fruit Slice VR</h2><div class="score">🍉 <span id="fruitScore">0</span> &nbsp; ❤️ <span id="fruitLives">3</span></div><button class="gamebtn" onclick="showHome()">← Игры</button></div><div class="arena"><canvas id="fruitCanvas"></canvas><div class="help">Сожми большой палец с указательным и проведи через фрукт. Бомбы режь нельзя.</div></div></section>
  <section id="neonScreen" class="screen"><div class="gamebar"><h2>Neon Dodge</h2><div class="score">⚡ <span id="neonScore">0</span> &nbsp; ⏱ <span id="neonTime">30</span></div><button class="gamebtn" onclick="showHome()">← Игры</button></div><div class="arena"><canvas id="neonCanvas"></canvas><div class="help">Двигай указателем рукой. Не сталкивайся с голубыми метеорами.</div></div></section>
  <section id="stackScreen" class="screen"><div class="gamebar"><h2>Stack Rush</h2><div class="score">🏗️ <span id="stackHeight">0</span></div><button class="gamebtn" onclick="showHome()">← Игры</button></div><div class="arena"><canvas id="stackCanvas"></canvas><div class="help">Следи за блоком и сделай pinch, когда он совпадёт с предыдущим.</div></div></section>
  <div id="gameOverlay"><div class="overlayBox"><h2 id="overTitle">Готово</h2><p id="overText"></p><button class="gamebtn primary" onclick="resetCurrent()">Заново</button></div></div>
</div>
<div class="row" style="margin-top:14px"><button class="btn primary" onclick="post('home')">На рабочий стол</button></div>
""",
        scripts: """
window.post=function(id){try{window.webkit.messageHandlers.handarApp.postMessage({id:id});}catch(e){}};
const screens={home:document.getElementById('homeScreen'),fruit:document.getElementById('fruitScreen'),neon:document.getElementById('neonScreen'),stack:document.getElementById('stackScreen')};let current='home',pressed=false;
function show(k){Object.keys(screens).forEach(x=>screens[x].classList.toggle('active',x===k));current=k;document.getElementById('gameOverlay').style.display='none';}
function showHome(){show('home');stopLoops();}
function overlay(t,m){document.getElementById('overTitle').textContent=t;document.getElementById('overText').textContent=m;document.getElementById('gameOverlay').style.display='flex';stopLoops();}
function resetCurrent(){document.getElementById('gameOverlay').style.display='none';if(current==='fruit')startFruit();else if(current==='neon')startNeon();else if(current==='stack')startStack();}
function stopLoops(){fruitRunning=false;neonRunning=false;stackRunning=false;}
function pointerPos(canvas,e){const r=canvas.getBoundingClientRect();return{x:Math.max(0,Math.min(r.width,e.clientX-r.left)),y:Math.max(0,Math.min(r.height,e.clientY-r.top))}}
// Fruit Slice VR
const fc=document.getElementById('fruitCanvas'),fx=fc.getContext('2d');let fruitRunning=false,fruitItems=[],fruitTrail=[],fruitScore=0,fruitLives=3,fruitLast=0,fruitSpawn=0;
function fitCanvas(canvas){const r=canvas.parentElement.getBoundingClientRect(),d=devicePixelRatio||1;canvas.width=r.width*d;canvas.height=r.height*d;canvas.style.width=r.width+'px';canvas.style.height=r.height+'px';return [r.width,r.height]}
function startFruit(){show('fruit');[fruitW,fruitH]=fitCanvas(fc);fruitScore=0;fruitLives=3;fruitItems=[];fruitTrail=[];fruitRunning=true;fruitLast=performance.now();fruitSpawn=0;document.getElementById('fruitScore').textContent='0';document.getElementById('fruitLives').textContent='3';requestAnimationFrame(fruitLoop)}let fruitW=1,fruitH=1;
const fruitSet=[['🍉',30],['🍊',25],['🍓',20],['🍎',22],['🍍',35],['🥝',24],['🍋',18]];
function fruitAdd(){const d=devicePixelRatio||1;const [e,p]=fruitSet[(Math.random()*fruitSet.length)|0];fruitItems.push({x:55+Math.random()*(fruitW-110),y:fruitH+40,vx:(Math.random()-.5)*3.2,vy:-11-Math.random()*5,r:28+Math.random()*9,e,p,b:Math.random()<.10});}
function fruitMove(e){const p=pointerPos(fc,e),q=fruitTrail.length?fruitTrail[fruitTrail.length-1]:p;fruitTrail.push(p);if(fruitTrail.length>12)fruitTrail.shift();if(pressed)fruitSlice(q,p)}
function fruitSlice(a,b){for(let i=fruitItems.length-1;i>=0;i--){const o=fruitItems[i],abx=b.x-a.x,aby=b.y-a.y,t=Math.max(0,Math.min(1,((o.x-a.x)*abx+(o.y-a.y)*aby)/(abx*abx+aby*aby||1))),px=a.x+t*abx,py=a.y+t*aby;if(Math.hypot(o.x-px,o.y-py)<o.r+10){if(o.b){fruitLives--;document.getElementById('fruitLives').textContent=fruitLives;if(fruitLives<=0){fruitRunning=false;overlay('Фрукты закончились','Счёт: '+fruitScore);}}else fruitScore+=o.p;document.getElementById('fruitScore').textContent=fruitScore;fruitItems.splice(i,1);}}}
function fruitLoop(t){if(!fruitRunning)return;const d=devicePixelRatio||1;fx.setTransform(d,0,0,d,0,0);fx.clearRect(0,0,fruitW,fruitH);fruitSpawn-=t-fruitLast;fruitLast=t;if(fruitSpawn<=0){fruitAdd();if(Math.random()<.35)fruitAdd();fruitSpawn=580+Math.random()*430}for(let i=fruitItems.length-1;i>=0;i--){const o=fruitItems[i];o.x+=o.vx;o.vy+=.42;o.y+=o.vy;fx.save();fx.translate(o.x,o.y);fx.font=(o.r*2)+'px system-ui';fx.textAlign='center';fx.textBaseline='middle';fx.shadowBlur=18;fx.shadowColor=o.b?'#ef4444':'#ffd34d';fx.fillText(o.b?'💣':o.e,0,0);fx.restore();if(o.y>fruitH+70){if(!o.b)fruitLives--;fruitItems.splice(i,1);document.getElementById('fruitLives').textContent=fruitLives;if(fruitLives<=0){fruitRunning=false;overlay('Фрукты закончились','Счёт: '+fruitScore);}}}fruitTrail.forEach((p,i)=>{if(i===0)return;const q=fruitTrail[i-1];fx.strokeStyle='rgba(255,255,255,'+(i/fruitTrail.length*.75)+')';fx.lineWidth=3+i*.35;fx.lineCap='round';fx.beginPath();fx.moveTo(q.x,q.y);fx.lineTo(p.x,p.y);fx.stroke()});requestAnimationFrame(fruitLoop)}
fc.addEventListener('pointermove',fruitMove);fc.addEventListener('pointerdown',e=>{pressed=true;fruitMove(e)});window.addEventListener('pointerup',()=>pressed=false);
// Neon Dodge
const nc=document.getElementById('neonCanvas'),nx=nc.getContext('2d');let neonRunning=false,neonObs=[],neonScore=0,neonStart=0,neonW=1,neonH=1,neonP={x:.5,y:.5};
function startNeon(){show('neon');[neonW,neonH]=fitCanvas(nc);neonRunning=true;neonObs=[];neonScore=0;neonStart=performance.now();document.getElementById('neonScore').textContent='0';requestAnimationFrame(neonLoop)}
function neonMove(e){const p=pointerPos(nc,e);neonP={x:p.x/neonW,y:p.y/neonH}}
function neonLoop(t){if(!neonRunning)return;const d=devicePixelRatio||1;nx.setTransform(d,0,0,d,0,0);nx.clearRect(0,0,neonW,neonH);const elapsed=t-neonStart,left=Math.max(0,30000-elapsed);document.getElementById('neonTime').textContent=Math.ceil(left/1000);if(left<=0){neonRunning=false;overlay('Раунд окончен','Счёт: '+neonScore);return}if(Math.random()<.045)neonObs.push({x:Math.random()*neonW,y:-25,r:11+Math.random()*15,v:2.8+Math.random()*4});const px=neonP.x*neonW,py=neonP.y*neonH;for(let i=neonObs.length-1;i>=0;i--){const o=neonObs[i];o.y+=o.v;if(Math.hypot(o.x-px,o.y-py)<o.r+23){neonRunning=false;overlay('Попадание!','Счёт: '+neonScore);return}if(o.y>neonH+40){neonObs.splice(i,1);neonScore++;document.getElementById('neonScore').textContent=neonScore}}nx.strokeStyle='rgba(34,211,238,.16)';for(let i=0;i<16;i++){const a=i*Math.PI/8;nx.beginPath();nx.moveTo(px,py);nx.lineTo(px+Math.cos(a)*Math.max(neonW,neonH),py+Math.sin(a)*Math.max(neonW,neonH));nx.stroke()}neonObs.forEach(o=>{nx.beginPath();nx.fillStyle='#38bdf8';nx.shadowBlur=24;nx.shadowColor='#22d3ee';nx.arc(o.x,o.y,o.r,0,Math.PI*2);nx.fill()});nx.shadowBlur=0;nx.beginPath();nx.fillStyle='#fff';nx.arc(px,py,17,0,Math.PI*2);nx.fill();nx.strokeStyle='#67e8f9';nx.lineWidth=4;nx.stroke();requestAnimationFrame(neonLoop)}
nc.addEventListener('pointermove',neonMove);nc.addEventListener('pointerdown',neonMove);
// Stack Rush
const sc=document.getElementById('stackCanvas'),sx=sc.getContext('2d');let stackRunning=false,stackBlocks=[],stackMoving=null,stackDir=1,stackW=1,stackH=1,stackHeight=0,stackPhase=0;
function startStack(){show('stack');[stackW,stackH]=fitCanvas(sc);stackRunning=true;stackHeight=0;document.getElementById('stackHeight').textContent='0';stackBlocks=[{x:stackW/2-110,y:stackH-50,w:220,h:32}];stackMoving={x:0,y:stackH-86,w:220,h:32};stackPhase=0;requestAnimationFrame(stackLoop)}
function stackMove(e){const p=pointerPos(sc,e);stackPhase=p.x/stackW;if(stackMoving&&stackRunning)stackMoving.x=Math.max(0,Math.min(stackW-stackMoving.w,p.x-stackMoving.w/2))}
function stackCut(){if(!stackRunning||!stackMoving)return;const top=stackBlocks[stackBlocks.length-1],l=Math.max(top.x,stackMoving.x),r=Math.min(top.x+top.w,stackMoving.x+stackMoving.w);if(r-l<26){stackRunning=false;overlay('Башня упала','Высота: '+stackHeight);return}const nw=r-l;stackBlocks.push({x:l,y:top.y-36,w:nw,h:32});stackMoving={x:0,y:top.y-72,w:nw,h:32};stackHeight++;document.getElementById('stackHeight').textContent=stackHeight}
function stackLoop(){if(!stackRunning)return;const d=devicePixelRatio||1;sx.setTransform(d,0,0,d,0,0);sx.clearRect(0,0,stackW,stackH);if(stackMoving){stackMoving.x+=stackDir*(3.5+Math.min(6,stackHeight*.12));if(stackMoving.x<=0){stackMoving.x=0;stackDir=1}if(stackMoving.x+stackMoving.w>=stackW){stackMoving.x=stackW-stackMoving.w;stackDir=-1}}stackBlocks.forEach((b,i)=>{sx.fillStyle=i%2?'#fbbf24':'#fb923c';sx.shadowBlur=16;sx.shadowColor='#f59e0b';sx.fillRect(b.x,b.y,b.w,b.h);sx.shadowBlur=0;sx.fillStyle='rgba(255,255,255,.25)';sx.fillRect(b.x,b.y,b.w,3)});if(stackMoving){sx.fillStyle='#fde68a';sx.fillRect(stackMoving.x,stackMoving.y,stackMoving.w,stackMoving.h)}requestAnimationFrame(stackLoop)}
sc.addEventListener('pointermove',stackMove);sc.addEventListener('pointerdown',e=>{stackMove(e);stackCut()});
addEventListener('resize',()=>{if(current==='fruit')[fruitW,fruitH]=fitCanvas(fc);if(current==='neon')[neonW,neonH]=fitCanvas(nc);if(current==='stack')[stackW,stackH]=fitCanvas(sc)});
"""
    )
    private static let vrSettingsHTML = htmlPage(
        title: "Настройки",
        icon: "вљ™",
        accent: "#6b7280",
        body: """
<div class="hero"><div class="bigicon">⚙</div><div><h1>VR Settings</h1><p>Быстрые действия для шлема. Подробная физическая калибровка остаётся в обычном меню HandAR.</p></div></div>
<p id="aim-state">Управление</p><div class="row"><button class="btn primary" onclick="post('aim-head')">Отдых рук · головой</button><button class="btn" onclick="post('aim-hand')">Управлять рукой</button></div><p>Поверни голову к кнопке и задержись на секунду. Для повторного клика отведи прицел. В кинотеатре используй пульт.</p>
<div class="row"><button class="btn primary" onclick="post('center')">Перецентрировать экран</button><button class="btn" onclick="post('calibrate')">Совместить изображения</button><button class="btn" onclick="post('controller-diagnostics')">Диагностика VR BOX</button><button class="btn" onclick="post('exit')">Выйти из VR</button></div>
<div style="margin-top:24px"><p><b>О контроллере:</b> приложение пытается получать Game Controller и motion-профиль. Если iOS не отдаёт VR BOX как контроллер, этот режим не может изобрести его сигналы.</p><p class="small">Нативные сторонние iPhone-приложения нельзя встроить внутрь окна HandAR. Поэтому значки на VR Desktop открывают VR-версии на базе WKWebView. Системный iOS запуск возможен только как отдельный переход из приложения.</p></div>
"""
    )

    private func applySpatialSurface(home: Bool, transparent: Bool) {
        spatialHomeVisible = home
        browser.isOpaque = !transparent
        browser.backgroundColor = transparent ? .clear : .white
        browser.scrollView.backgroundColor = transparent ? .clear : .white
        browserFrameNode.isHidden = transparent
        browserPlaneGeometry.cornerRadius = home ? 0 : 0.045
        toolbarNode.isHidden = transparent || cinemaActive || isCinemaMode
    }

    private func openVRDesktop() {
        if graffitiActive { stopGraffiti(restoreCamera: true); resetBrowserAnchor() }
        if panoramaActive { cancelHandInteraction(); panorama.stop(); resetBrowserAnchor() }
        if directVideoActive { hideDirectVideoStage() }
        isCinemaMode = false
        updatePanelSize(width: browserWorldWidth)
        toolbarNode.isHidden = true
        applySpatialSurface(home: true, transparent: true)
        browser.loadHTMLString(Self.vrDesktopHTML, baseURL: URL(string: "https://handar.vision/"))
        startBrowserCapture()
    }

    private func openVRApp(id: String) {
        if graffitiActive { stopGraffiti(restoreCamera: true); resetBrowserAnchor() }
        if panoramaActive { cancelHandInteraction(); panorama.stop(); resetBrowserAnchor() }
        if directVideoActive { hideDirectVideoStage(); startBrowserCapture() }
        isCinemaMode = false
        updatePanelSize(width: browserWorldWidth)
        toolbarNode.isHidden = false
        applySpatialSurface(home: false, transparent: true)
        switch id {
        case "home":
            openVRDesktop()
        case "safari", "google":
            openExternalPage(Self.homeURL)
        case "youtube":
            openExternalPage(Self.youTubeURL)
        case "tiktok":
            openExternalPage(Self.tikTokURL)
        case "telegram":
            openExternalPage(Self.telegramURL)
        case "discord":
            openExternalPage(Self.discordURL)
        case "spotify":
            openExternalPage(Self.spotifyURL)
        case "maps":
            openExternalPage(Self.mapsURL)
        case "graffiti":
            startGraffiti()
        case "travel":
            browser.loadHTMLString(Self.vrTravelHTML, baseURL: URL(string: "https://handar.vision/"))
        case "panorama-burj":
            startPanorama(id: "burj-khalifa-night")
        case "gmail":
            openExternalPage(Self.gmailURL)
        case "reddit":
            openExternalPage(Self.redditURL)
        case "wikipedia":
            openExternalPage(Self.wikipediaURL)
        case "notes":
            browser.loadHTMLString(Self.vrNotesHTML, baseURL: URL(string: "https://handar.vision/"))
        case "calculator":
            browser.loadHTMLString(Self.vrCalculatorHTML, baseURL: URL(string: "https://handar.vision/"))
        case "photos":
            browser.loadHTMLString(Self.vrPhotosHTML, baseURL: URL(string: "https://handar.vision/"))
        case "files":
            browser.loadHTMLString(Self.vrFilesHTML, baseURL: URL(string: "https://handar.vision/"))
        case "messages":
            browser.loadHTMLString(Self.vrMessagesHTML, baseURL: URL(string: "https://handar.vision/"))
        case "phone":
            browser.loadHTMLString(Self.vrPhoneHTML, baseURL: URL(string: "https://handar.vision/"))
        case "games":
            browser.loadHTMLString(Self.vrGamesHTML, baseURL: URL(string: "https://handar.vision/"))
        case "security-game":
            startSecurityVR()
        case "time-motion-game":
            startTimeMotionVR()
        case "cinema":
            enterCinema(url: nil)
        case "settings":
            browser.loadHTMLString(Self.vrSettingsHTML, baseURL: URL(string: "https://handar.vision/"))
        default:
            openVRDesktop()
        }
    }

    private func handleVRSystemAction(_ action: String) {
        switch action {
        case "aim-head": setPointerControlMode(.head)
        case "aim-hand": setPointerControlMode(.hand)
        case "home": openVRDesktop()
        case "environment-camera", "environment-dark":
            profile.passthrough = action == "environment-camera"
            profile.save()
            menu?.setProfile(profile)
        case "center": resetBrowserAnchor()
        case "calibrate": startLensCalibration()
        case "exit": leaveVRToMenu()
        case "controller-diagnostics": showVRBoxDiagnostics()
        default: break
        }
    }

    private func buildControllerHand() {
        let skin = SCNMaterial()
        skin.lightingModel = .physicallyBased
        skin.diffuse.contents = UIColor(red: 0.80, green: 0.60, blue: 0.43, alpha: 1)
        skin.roughness.contents = 0.62
        skin.metalness.contents = 0.0

        let palmGeometry = SCNBox(width: 0.145, height: 0.070, length: 0.048, chamferRadius: 0.022)
        palmGeometry.firstMaterial = skin
        let palm = SCNNode(geometry: palmGeometry)
        palm.position = SCNVector3(0, 0, 0)
        controllerHandRoot.addChildNode(palm)

        let fingerXs: [Float] = [-0.052, -0.017, 0.018, 0.053]
        for (index, x) in fingerXs.enumerated() {
            let length: CGFloat = index == 1 ? 0.084 : 0.073
            let geometry = SCNBox(width: 0.028, height: length, length: 0.028, chamferRadius: 0.012)
            geometry.firstMaterial = skin
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(Double(x), Double(0.040 + Float(length) * 0.5), 0)
            node.eulerAngles.x = index == 1 ? 0.02 : -0.12
            controllerHandRoot.addChildNode(node)
        }

        let thumbGeometry = SCNBox(width: 0.030, height: 0.078, length: 0.032, chamferRadius: 0.012)
        thumbGeometry.firstMaterial = skin
        let thumb = SCNNode(geometry: thumbGeometry)
        thumb.position = SCNVector3(-0.082, 0.005, 0.010)
        thumb.eulerAngles.z = -0.75
        controllerHandRoot.addChildNode(thumb)

        let tipGeometry = SCNSphere(radius: 0.011)
        tipGeometry.firstMaterial = pointerTipMaterial()
        controllerHandTip.geometry = tipGeometry
        controllerHandTip.renderingOrder = 240
        controllerHandRoot.addChildNode(controllerHandTip)

        controllerHandRoot.renderingOrder = 235
        controllerHandRoot.isHidden = true
        worldScene.rootNode.addChildNode(controllerHandRoot)
    }

    private func pointerTipMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.emission.contents = UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 1)
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        return m
    }
}


/// Two presentations of the same live layer subtree, with zero time offset.
final class MonoscopicWebReplicatorView: UIView {
    override class var layerClass: AnyClass { CAReplicatorLayer.self }
    var copyOffset: CGPoint = .zero {
        didSet {
            let copy=layer as! CAReplicatorLayer
            copy.instanceCount=2
            copy.instanceDelay=0
            copy.instanceTransform=CATransform3DMakeTranslation(copyOffset.x,copyOffset.y,0)
        }
    }
}

/// Legacy mask utility retained for its regression test; not used by the output.
final class DirectVideoLensMaskView: UIView {
    var leftCircle: CGRect = .zero { didSet { if oldValue != leftCircle { setNeedsDisplay() } } }
    var rightCircle: CGRect = .zero { didSet { if oldValue != rightCircle { setNeedsDisplay() } } }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(bounds)
        for (eye,circle) in [leftCircle,rightCircle].enumerated() {
            guard circle.width > 1, circle.height > 1 else { continue }
            context.saveGState()
            context.clip(to:CGRect(x:bounds.minX+CGFloat(eye)*bounds.width*0.5,
                                   y:bounds.minY,width:bounds.width*0.5,height:bounds.height))
            context.setBlendMode(.clear)
            context.fillEllipse(in:circle)
            context.restoreGState()
        }
    }
}


private extension MainViewController {
    func updateVRDesktopStatus() {
        let battery = UIDevice.current.batteryLevel
        let batteryText = battery >= 0 ? String(format: "%.0f%%", battery * 100) : "—"
        let aimText = usesHeadAim ? "Отдых рук: наведение головой" : "Управление рукой"
        let controllerText = controllerConnected ? "VR BOX" : "VR BOX — нет"
        let script = """
(function(){
  var a=document.getElementById('aim-state'); if(a) a.textContent='\(aimText)';
  var b=document.getElementById('battery'); if(b) b.textContent='🔋 \(batteryText)';
  var c=document.getElementById('controllerState'); if(c) c.textContent='\(controllerText)';
})();
"""
        browser.evaluateJavaScript(script, completionHandler: nil)
    }
}

extension MainViewController: WKNavigationDelegate, WKUIDelegate {
    private func reportVideoNavigationFailure(_ webView: WKWebView, error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        if directVideoActive, webView === directVideoLeft {
            let message = cinemaWebScreenActive ? "Не удалось загрузить видео. На пульте нажми «Обновить». " + error.localizedDescription : "Не удалось загрузить. Нажми «Обновить». " + error.localizedDescription
            liveLoadError = message
            setDirectVideoNotice(message)
            setCinemaWebRecovery(true)
        } else if webView === browser, cinemaActive, !directVideoActive {
            startCinemaWebFallback()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !panoramaActive, !graffitiActive else { return }
        guard directVideoActive, webView === directVideoLeft else {
            if webView === browser { browser.reload() }
            return
        }
        let key = ObjectIdentifier(webView)
        if liveProcessRecoveries.insert(key).inserted {
            directVideoGeneration = UUID()
            directVideoSyncInFlight = false
            cancelHandInteraction()
            setDirectVideoNotice("Восстанавливаю страницу…")
            webView.reload()
        } else {
            let message = cinemaWebScreenActive ? "Страница остановлена. На пульте нажми «Обновить»." : "Страница остановлена. Нажми «Обновить» или «Домой»."
            liveLoadError = message
            setDirectVideoNotice(message)
            setCinemaWebRecovery(true)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportVideoNavigationFailure(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportVideoNavigationFailure(webView, error: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if panoramaActive || graffitiActive { decisionHandler(.cancel); return }
        if webView === browser, navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != "handar.vision" {
            if inVR && !cinemaActive && !isCinemaMode {
                decisionHandler(.cancel)
                openExternalPage(url)
                return
            }
            applySpatialSurface(home: false, transparent: false)
            toolbarNode.isHidden = cinemaActive || isCinemaMode
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if directVideoActive, webView === directVideoLeft {
            liveLoadError = nil
            cinemaWebLoadStartedAt = CACurrentMediaTime()
            setCinemaWebRecovery(false)
        }
        if directVideoActive, webView === directVideoLeft {
            directVideoGeneration = UUID()
            directVideoSyncInFlight = false
            releasePointer()
            setDirectVideoNotice("Загружаю страницу…")
        }
        if webView === browser {
            snapshotGeneration = UUID()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !panoramaActive, !graffitiActive else { return }
        if directVideoActive, webView === directVideoLeft {
            liveLoadError = nil
            webView.evaluateJavaScript("window.__handarCinemaSurface = \(cinemaWebScreenActive ? "true" : "false"); window.__handarTuneDirectVideo ? window.__handarTuneDirectVideo() : null;", completionHandler: nil)
            if webView === directVideoLeft {
                setDirectVideoNotice(liveLoadError ?? (liveBrowserActive ? "" : "Если видео не началось, нажми ▶ на странице"))
                activateDirectVideoAudio()
            }
            if liveBrowserActive, !directVideoLeft.isLoading {
                setDirectVideoNotice(liveLoadError ?? "")
            }
            return
        }
        updateBrowserSnapshot()
        updateVRDesktopStatus()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

// MARK: - ARKit ----------------------------------------------------------------

final class ARStereoTrackingManager: NSObject, ARSessionDelegate {
    let session = ARSession()

    private let frameLock = NSLock()
    private var latestFrame: CameraFrame?
    private var cameraCoverage = SIMD2<Double>(0, 0)

    func setCameraCoverage(x: Double, y: Double) {
        frameLock.lock(); defer { frameLock.unlock() }
        cameraCoverage = SIMD2(x, y)
    }

    func projection(for frame: CameraFrame) -> CameraProjection? {
        frameLock.lock(); let coverage = cameraCoverage; frameLock.unlock()
        return frame.projection?.covering(x: coverage.x, y: coverage.y)
    }
    private var interfaceOrientation: UIInterfaceOrientation = .landscapeRight
    private var runState = CameraRunState()
    private var wallDetectionEnabled = false
    private let ultraWideCapture = UltraWideCapture()

    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?
    var onCamera: ((CameraFrame) -> Void)?
    var onAnchorUpdate: ((ARAnchor) -> Void)?
    var onFailure: ((String) -> Void)?

    override init() {
        super.init()
        ultraWideCapture.onFrame = { [weak self] frame in self?.publish(frame) }
    }
    deinit { ultraWideCapture.stop();session.pause() }

    private var currentMode: CameraMode? {
        frameLock.lock();defer{frameLock.unlock()};return runState.mode
    }
    private func reportFailure(_ message: String, mode: CameraMode, token suppliedToken: UInt64? = nil) {
        frameLock.lock();let token=suppliedToken ?? runState.generation;frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameLock.lock();let current=self.runState.isCurrent(token,mode:mode);self.frameLock.unlock()
            if current { self.onFailure?(message) }
        }
    }
    var latestFrameCopy: CameraFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    func isCurrent(_ frame: CameraFrame) -> Bool {
        frameLock.lock();defer{frameLock.unlock()}
        return runState.accepts(mode:frame.mode,timestamp:frame.timestamp)
    }
    func acceptsHand(timestamp: Double) -> Bool {
        frameLock.lock();defer{frameLock.unlock()}
        return runState.acceptsHand(timestamp:timestamp)
    }

    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        frameLock.lock();defer{frameLock.unlock()}
        interfaceOrientation = orientation
    }

    /// Матрица головы в мире с поправкой на ориентацию интерфейса.
    func headTransform(_ frame: CameraFrame) -> simd_float4x4 {
        frameLock.lock();let interfaceOrientation=self.interfaceOrientation;frameLock.unlock()
        return frame.camera.viewMatrix(for: interfaceOrientation).inverse
    }

    /// Луч из точки, найденной Vision, в мировые координаты.
    /// Считаем через интринсики камеры: никакого согласования вьюпортов.
    func worldRay(visionPoint: CGPoint) -> WorldRay? {
        guard let frame = latestFrameCopy else { return nil }

        guard let projection=projection(for: frame) else { return nil }

        // Vision отдаёт нормированные координаты ориентированного кадра
        // (начало — левый низ). Возвращаемся в координаты сырого кадра.
        frameLock.lock();let flipped=interfaceOrientation == .landscapeLeft;frameLock.unlock()
        let uv=CameraProjection.rawUV(vision:SIMD2(Double(visionPoint.x),Double(visionPoint.y)),landscapeLeft:flipped)
        let tangent=projection.tangent(rawUV:uv)
        guard tangent.x.isFinite,tangent.y.isFinite else { return nil }
        let directionInCamera=simd_normalize(SIMD3<Float>(Float(tangent.x),Float(tangent.y),-1))

        let transform = frame.camera.transform
        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        let origin = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        return WorldRay(origin: origin, direction: simd_normalize(rotation * directionInCamera))
    }

    func start(mode override: CameraMode? = nil) {
        pause() // Invalidate old source callbacks before opening a new run gate.
        let mode=override ?? CameraMode.load(ultraWideAvailable:UltraWideCapture.isAvailable)
        frameLock.lock()
        let token=runState.begin(mode,at:CACurrentMediaTime());latestFrame=nil
        frameLock.unlock()
        // Release the previous physical camera before opening the other pipeline.
        ultraWideCapture.stop { [weak self] in
            guard let self else { return }
            self.frameLock.lock();let current=self.runState.isCurrent(token,mode:mode);self.frameLock.unlock()
            guard current else { return }
            if mode == .ultraWide {
                self.ultraWideCapture.start { [weak self] message in self?.reportFailure(message,mode:.ultraWide,token:token) }
            }
            else { self.startWorldTracking() }
        }
    }

    func setWallDetectionEnabled(_ enabled: Bool) {
        frameLock.lock(); wallDetectionEnabled = enabled; frameLock.unlock()
        guard currentMode == .worldTracking,
              let configuration = session.configuration as? ARWorldTrackingConfiguration else { return }
        configuration.planeDetection = enabled ? [.vertical] : []
        session.run(configuration, options: [])
    }

    func detectedWallHit(ray: WorldRay) -> ARRaycastResult? {
        guard currentMode == .worldTracking else { return nil }
        frameLock.lock(); let enabled = wallDetectionEnabled; frameLock.unlock()
        guard enabled else { return nil }
        let query = ARRaycastQuery(origin: ray.origin, direction: ray.direction,
                                  allowing: .existingPlaneGeometry, alignment: .vertical)
        return session.raycast(query).first { $0.anchor is ARPlaneAnchor }
    }

    private func startWorldTracking() {
        guard ARWorldTrackingConfiguration.isSupported else {
            reportFailure("Этот iPhone не поддерживает ARKit World Tracking.",mode:.worldTracking)
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        frameLock.lock(); let detectWalls = wallDetectionEnabled; frameLock.unlock()
        configuration.planeDetection = detectWalls ? [.vertical] : []
        configuration.environmentTexturing = ARWorldTrackingConfiguration.EnvironmentTexturing.none

        // Реконструкция сцены и текстурирование окружения стоят кадров,
        // а в стереорежиме бюджет кадра важнее.
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
        ultraWideCapture.stop()
        frameLock.lock()
        runState.stop()
        latestFrame = nil
        frameLock.unlock()
    }

    func add(anchor: ARAnchor) {
        guard currentMode == .worldTracking else { return }
        session.add(anchor: anchor)
    }

    func remove(anchor: ARAnchor) {
        guard currentMode == .worldTracking else { return }
        session.remove(anchor: anchor)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        publish(CameraFrame(frame))
    }

    private func publish(_ frame: CameraFrame) {
        frameLock.lock()
        guard runState.accepts(mode:frame.mode,timestamp:frame.timestamp) else { frameLock.unlock();return }
        latestFrame = frame
        let orientation=interfaceOrientation
        frameLock.unlock()

        onFrame?(frame.capturedImage, imageOrientation(for:orientation))
        onCamera?(frame)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard currentMode == .worldTracking else { return }
        anchors.forEach { onAnchorUpdate?($0) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard currentMode == .worldTracking else { return }
        reportFailure("ARKit завершил сессию: \(error.localizedDescription)",mode:.worldTracking)
    }

    private func imageOrientation(for orientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .down
        case .landscapeRight:
            return .up
        default:
            return .up
        }
    }
}

// MARK: - Отслеживание руки ----------------------------------------------------

final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        if let latest = VNDetectHumanHandPoseRequest.supportedRevisions.max() { request.revision = latest }
        return request
    }()
    private let queue = DispatchQueue(label: "handar.vision", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)
    private var lastProcessedTime: CFTimeInterval = -.infinity

    private struct HandState {
        var trackingGeneration: UInt64 = 0
        var joints: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        var jointAges: [VNHumanHandPoseObservation.JointName: Int] = [:]
        var pinch = StablePinchGesture()
        var fist = StableFistGesture()
        var occludedFist = OccludedFistGesture()
        var aim = PinchAimStabilizer()
        var previousWrist: SIMD2<Double>?
        var previousPalm: Double?

        mutating func reset() {
            trackingGeneration &+= 1
            joints.removeAll(keepingCapacity: true)
            jointAges.removeAll(keepingCapacity: true)
            pinch.cancel() // Keep the generation monotonic across loss/reacquisition.
            fist.reset()
            occludedFist.reset()
            aim.reset()
            previousWrist = nil
            previousPalm = nil
        }
    }
    private var leftState = HandState()
    private var rightState = HandState()
    var onUpdate: ((HandSample?, HandSample?) -> Void)?

    func reset() {
        queue.async { [weak self] in
            self?.leftState.reset()
            self?.rightState.reset()
        }
    }

    func process(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard gate.wait(timeout: .now()) == .success else { return }
        let now = CACurrentMediaTime()
        let budget = VRPerformanceBudget(thermalLevel: ProcessInfo.processInfo.thermalState.rawValue)
        guard now-lastProcessedTime+0.001 >= budget.handFrameInterval else { gate.signal(); return }
        lastProcessedTime = now
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.gate.signal() }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([self.request])
                // Never turn unknown chirality into "right", or update one hand twice.
                var candidates: [TrackedHand: (VNHumanHandPoseObservation, Float)] = [:]
                for observation in self.request.results ?? [] {
                    let side: TrackedHand
                    switch observation.chirality {
                    case .left: side = .left
                    case .right: side = .right
                    default: continue
                    }
                    guard let points = try? observation.recognizedPoints(.all) else { continue }
                    let score = min(points[.wrist]?.confidence ?? 0, points[.middleMCP]?.confidence ?? 0)
                    if score > (candidates[side]?.1 ?? -1) { candidates[side] = (observation,score) }
                }
                var width = Double(CVPixelBufferGetWidth(pixelBuffer))
                var height = Double(CVPixelBufferGetHeight(pixelBuffer))
                switch orientation {
                case .left, .right, .leftMirrored, .rightMirrored: swap(&width,&height)
                default: break
                }
                let size = SIMD2<Double>(width,height)
                let left = candidates[.left].flatMap { self.sample($0.0, side: .left, state: &self.leftState, size: size, at: now) }
                let right = candidates[.right].flatMap { self.sample($0.0, side: .right, state: &self.rightState, size: size, at: now) }
                if left == nil { self.leftState.reset() }
                if right == nil { self.rightState.reset() }
                self.onUpdate?(left,right)
            } catch {
                self.leftState.reset()
                self.rightState.reset()
                self.onUpdate?(nil,nil)
            }
        }
    }

    private func sample(_ observation: VNHumanHandPoseObservation, side: TrackedHand,
                        state: inout HandState, size: SIMD2<Double>, at time: Double) -> HandSample? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        func fresh(_ joint: VNHumanHandPoseObservation.JointName, confidence: Float = 0.55) -> CGPoint? {
            guard let point = points[joint], point.confidence >= confidence else { return nil }
            return point.location
        }
        func pixel(_ point: CGPoint) -> SIMD2<Double> {
            SIMD2(Double(point.x)*size.x,Double(point.y)*size.y)
        }
        guard let wrist = fresh(.wrist), let middleBase = fresh(.middleMCP) else { return nil }
        let indexBase = fresh(.indexMCP)
        let index = fresh(.indexTip,confidence:0.55)
        let thumb = fresh(.thumbTip,confidence:0.55)
        let middle = fresh(.middleTip)
        var filtered: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        for (joint,point) in points where point.confidence >= 0.40 {
            filtered[joint] = smooth(state.joints[joint],point.location,
                                     alpha:adaptiveAlpha(previous:state.joints[joint],current:point.location))
            state.jointAges[joint] = 0
        }
        // Short visual grace only. Cached joints NEVER make gesture decisions.
        for (joint,point) in state.joints where filtered[joint] == nil {
            let age = (state.jointAges[joint] ?? 0)+1
            state.jointAges[joint] = age
            if age <= 3 { filtered[joint] = point }
        }
        func curlPoint(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            fresh(joint).map { CGPoint(x:Double($0.x)*size.x,y:Double($0.y)*size.y) }
        }
        let triplets: [(VNHumanHandPoseObservation.JointName,VNHumanHandPoseObservation.JointName,VNHumanHandPoseObservation.JointName)] = [
            (.indexMCP,.indexPIP,.indexDIP),(.middleMCP,.middlePIP,.middleDIP),
            (.ringMCP,.ringPIP,.ringDIP),(.littleMCP,.littlePIP,.littleDIP)
        ]
        var curled = 0, known = 0
        for (mcp,pip,dip) in triplets {
            if let closed = fingerCurled(mcp:curlPoint(mcp),pip:curlPoint(pip),dip:curlPoint(dip)) {
                known += 1
                if closed { curled += 1 }
            }
        }
        // A pinch with the other three fingers curled is not a fist: the index
        // itself must be observably curled before panel grabbing is possible.
        let indexCurl = fingerCurled(mcp:curlPoint(.indexMCP),pip:curlPoint(.indexPIP),dip:curlPoint(.indexDIP))
        var measurement: HandPinchMeasurement?
        if let index, let thumb, let indexBase {
            measurement = HandPinchGeometry.measure(thumb:pixel(thumb),index:pixel(index),wrist:pixel(wrist),
                indexBase:pixel(indexBase),middleBase:pixel(middleBase),littleBase:fresh(.littleMCP).map(pixel))
        }
        let foldedIndex = index.flatMap { tip in indexBase.map { base in
            HandPinchGeometry.distance(pixel(wrist),pixel(tip)) < HandPinchGeometry.distance(pixel(wrist),pixel(base))*0.85
        } } ?? false
        let visibleTips = [VNHumanHandPoseObservation.JointName.indexTip,.middleTip,.ringTip,.littleTip]
            .filter { fresh($0) != nil }.count
        // Keep Vision calls and CGFloat comparisons in separate expressions:
        // Apple's Swift compiler can exhaust its solver on the combined chain.
        let wristReliable: Bool = fresh(.wrist, confidence: 0.7) != nil
        let middleReliable: Bool = fresh(.middleMCP, confidence: 0.7) != nil
        let indexBaseReliable: Bool = fresh(.indexMCP, confidence: 0.7) != nil
        let littleBaseReliable: Bool = fresh(.littleMCP, confidence: 0.7) != nil
        func insideFrameMargin(_ point: CGPoint) -> Bool {
            guard point.x > 0.05, point.x < 0.95 else { return false }
            guard point.y > 0.05, point.y < 0.95 else { return false }
            return true
        }
        let palmJointsReliable: Bool = wristReliable && middleReliable
        let sideBaseReliable: Bool = indexBaseReliable || littleBaseReliable
        let wristInside: Bool = insideFrameMargin(wrist)
        let middleInside: Bool = insideFrameMargin(middleBase)
        let palmInside: Bool = wristInside && middleInside
        let palmSafe: Bool = palmJointsReliable && sideBaseReliable && palmInside
        let hiddenFist = state.occludedFist.update(visibleTips:visibleTips,
            palmReliable:palmSafe,pinchEngaged:state.pinch.isEngaged,
            hiddenAllowed:index == nil && known < 3,at:time)
        let allowsFist = hiddenFist || HandGestureIntent.allowsFist(indexCurled:indexCurl,curled:curled,known:known,
            pinchRatio:measurement?.ratio,pinchEngaged:state.pinch.isEngaged,indexFoldedIntoPalm:foldedIndex)
        let fist = state.fist.update(curled:hiddenFist ? 4 : (allowsFist ? curled : 0),
                                    known:hiddenFist ? 4 : (indexCurl == nil ? 0 : known),at:time)
        var discontinuity = false
        if let palm = measurement?.palmSpan, let previousPalm = state.previousPalm,
           let previousWrist = state.previousWrist {
            let scale = palm / previousPalm
            discontinuity = scale < 0.55 || scale > 1.8 || HandPinchGeometry.distance(pixel(wrist),previousWrist) > palm*0.9
        }
        if discontinuity { state.trackingGeneration &+= 1 }
        let transition = state.pinch.update(ratio:measurement?.ratio,confident:measurement != nil && !discontinuity,
                                            grabbing:fist || allowsFist,at:time)
        if transition == .cancelled { state.aim.reset() }
        state.previousWrist = pixel(wrist)
        state.previousPalm = measurement?.palmSpan
        state.joints = filtered
        // A fist may occlude fingertips. Aim it using a fresh palm joint.
        let fingerPoint = index.map { filtered[.indexTip] ?? $0 } ?? (filtered[.middleMCP] ?? middleBase)
        let stableWrist = filtered[.wrist] ?? wrist, stableBase = filtered[.middleMCP] ?? middleBase
        let palmPoint = CGPoint(x:(stableWrist.x+stableBase.x)*0.5,y:(stableWrist.y+stableBase.y)*0.5)
        let approaching = state.pinch.isOpenConfirmed && (measurement?.ratio ?? .infinity) < state.pinch.configuration.openRatio
        let stablePoint = state.aim.update(index:SIMD2(Double(fingerPoint.x),Double(fingerPoint.y)),
            palm:SIMD2(Double(palmPoint.x),Double(palmPoint.y)),engaged:state.pinch.isEngaged || approaching,
            released:transition == .released)
        let pointer = CGPoint(x:stablePoint.x,y:stablePoint.y)
        let maskJoints = points.reduce(into: [VNHumanHandPoseObservation.JointName: CGPoint]()) { result, entry in
            if entry.value.confidence >= 0.55 { result[entry.key] = entry.value.location }
        }
        return HandSample(hand:side,timestamp:time,generation:state.pinch.generation,trackingGeneration:state.trackingGeneration,
            indexTip:pointer,middleTip:middle.map {filtered[.middleTip] ?? $0} ?? pointer,
            thumbTip:thumb.map {filtered[.thumbTip] ?? $0} ?? pointer,joints:filtered,
            maskJoints:maskJoints,imageSize:size,
            clickPinch:state.pinch.isDown,clickBegan:false,clickOpenConfirmed:state.pinch.isOpenConfirmed,
            grabPinch:fist,isFist:fist)
    }
}

@inline(__always)
private func smooth(_ old: CGPoint?, _ new: CGPoint, alpha: CGFloat) -> CGPoint {
    guard let old else { return new }
    return CGPoint(
        x: old.x + (new.x - old.x) * alpha,
        y: old.y + (new.y - old.y) * alpha
    )
}

@inline(__always)
private func adaptiveAlpha(previous: CGPoint?, current: CGPoint) -> CGFloat {
    guard let previous else { return 1.0 }
    let jump = min(distance(previous, current), 0.30)
    return min(0.62, max(0.30, 0.30 + jump * 1.15))
}

@inline(__always)
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

/// Палец согнут, если угол между сегментами MCP→PIP и PIP→DIP больше ~80°.
/// nil — сустав не виден, вердикт не выдаём.
@inline(__always)
private func fingerCurled(
    mcp: CGPoint?,
    pip: CGPoint?,
    dip: CGPoint?
) -> Bool? {
    guard let mcp, let pip, let dip else { return nil }
    let v1x = pip.x - mcp.x
    let v1y = pip.y - mcp.y
    let v2x = dip.x - pip.x
    let v2y = dip.y - pip.y
    let m1 = hypot(v1x, v1y)
    let m2 = hypot(v2x, v2y)
    guard m1 > 1e-4, m2 > 1e-4 else { return nil }
    let cosAngle = max(-1.0, min(1.0, (v1x * v2x + v1y * v2y) / (m1 * m2)))
    return acos(cosAngle) > 1.40 // ~80°
}

// MARK: - Ввод в страницу ------------------------------------------------------

final class WebInputBridge {
    private var lastHoverPoint: CGPoint?
    private weak var lastHoverWebView: WKWebView?
    private var lastHoverTime: CFTimeInterval = -.infinity
    private weak var pressedWebView: WKWebView?
    private var pointerDown = false
    private weak var dwellWebView: WKWebView?

    func update(normalizedPoint: CGPoint, pinch: Bool, webView: WKWebView, allowBegin: Bool = true, dwell: Bool = false) {
        let x = normalizedPoint.x * webView.bounds.width
        let y = normalizedPoint.y * webView.bounds.height
        guard x.isFinite, y.isFinite else { release(webView:webView); return }
        if let previous=dwellWebView, previous !== webView || !dwell || pinch {
            dispatch("window.__handarCancelDwell && window.__handarCancelDwell();",to:previous)
            dwellWebView=nil
        }
        if dwell && !pinch && !pointerDown {
            dwellWebView=webView
            dispatch("window.__handarDwell && window.__handarDwell(\(x),\(y));",to:webView)
        }
        if pointerDown, let previous = pressedWebView, previous !== webView { release(webView:previous) }
        if pinch && !pointerDown {
            guard allowBegin else { return }
            pointerDown = true
            pressedWebView = webView
            let slop = max(8,min(18,webView.bounds.width*0.012))
            dispatch("window.__handarPointerDown(\(x),\(y),1,\(slop),\(dwell ? "true" : "false"));",to:webView)
        } else if pinch && pointerDown {
            dispatch("window.__handarPointerMove(\(x),\(y),1);",to:webView)
        } else if !pinch && pointerDown {
            pointerDown = false
            pressedWebView = nil
            dispatch("window.__handarPointerUp(\(x),\(y),1);",to:webView)
        } else {
            let now = CACurrentMediaTime()
            let moved = lastHoverPoint.map { hypot(x-$0.x,y-$0.y)>=2 } ?? true
            if lastHoverWebView !== webView || (moved && now-lastHoverTime>=1.0/30) || now-lastHoverTime>=0.25 {
                lastHoverTime = now
                lastHoverPoint = CGPoint(x:x,y:y)
                lastHoverWebView = webView
                dispatch("window.__handarHover(\(x),\(y));",to:webView)
            }
        }
    }

    func release(webView: WKWebView) {
        if dwellWebView === webView {
            dispatch("window.__handarCancelDwell && window.__handarCancelDwell();",to:webView)
            dwellWebView=nil
        }
        if lastHoverWebView === webView, lastHoverPoint != nil {
            dispatch("window.__handarClearHover && window.__handarClearHover();",to:webView)
            lastHoverPoint = nil
            lastHoverWebView = nil
        }
        guard pointerDown, pressedWebView === webView else { return }
        pointerDown = false
        pressedWebView = nil
        dispatch("window.__handarPointerCancel && window.__handarPointerCancel(0,0,1);",to:webView)
    }
    private func dispatch(_ script: String, to webView: WKWebView) {
        webView.evaluateJavaScript(script,completionHandler:nil)
    }
}

// MARK: - Меню и калибровка ----------------------------------------------------

final class MainMenuView: UIView {
    var onEnter: (() -> Void)?
    var onProfileChange: ((VRProfile) -> Void)?
    var onCalibration: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onCinema: ((String) -> Void)?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let enterButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let passthroughSwitch = UISwitch()
    private let cameraSelector = UISegmentedControl(items:["0,5× · широкий","AR 1×"])
    private let cameraNote = UILabel()
    private let aimSelector = UISegmentedControl(items:["Рукой", "Отдых рук · головой"])
    private let clickSelector = UISegmentedControl(items:["Удержание · 1 сек", "Щипок"])
    private let cinemaField = UITextField()
    private let cinemaButton = UIButton(type: .system)
    private var profile: VRProfile

    private let ipdRow = SliderRow(title: "Межзрачковое расстояние", unit: "мм", minimum: 52, maximum: 76, step: 0.5)
    private let horizontalRow=SliderRow(title:"Телефон: сдвиг по горизонтали",unit:"мм",minimum:-8,maximum:8,step:0.1)
    private let verticalRow=SliderRow(title:"Телефон: сдвиг по высоте",unit:"мм",minimum:-8,maximum:8,step:0.1)
    private let verticalMatchRow=SliderRow(title:"Совмещение по вертикали",unit:"мм",minimum:-4,maximum:4,step:0.05)
    private let lensRow = SliderRow(title: "Расстояние между линзами", unit: "мм", minimum: 52, maximum: 76, step: 0.5)
    private let depthRow = SliderRow(title: "Глаз → экран", unit: "мм", minimum: 30, maximum: 70, step: 0.5)
    private let k1Row = SliderRow(title: "Дисторсия k1", unit: "", minimum: 0, maximum: 0.8, step: 0.005)
    private let k2Row = SliderRow(title: "Дисторсия k2", unit: "", minimum: -0.2, maximum: 0.6, step: 0.005)

    init(frame: CGRect, profile: VRProfile) {
        self.profile = profile
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.18, alpha: 1)
        build()
        applyProfile()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        titleLabel.text = "HandAR Vision"
        let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.isUserInteractionEnabled = false
        insertSubview(glass, at: 0)
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 26, weight: .medium)
        titleLabel.textAlignment = .center

        subtitleLabel.text = "iPhone 13 · VR BOX 3 · один кадр → два глаза"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textAlignment = .center

        var config = UIButton.Configuration.filled()
        config.title = "Открыть пространство"
        config.baseForegroundColor = UIColor(white: 0.12, alpha: 1)
        config.baseBackgroundColor = UIColor(white: 0.95, alpha: 1)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 34)
        enterButton.configuration = config
        enterButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        enterButton.addAction(UIAction { [weak self] _ in self?.onEnter?() }, for: .touchUpInside)

        let diagnosticsButton = UIButton(type: .system)
        diagnosticsButton.setTitle("ПРОВЕРИТЬ VR BOX 3.0", for: .normal)
        diagnosticsButton.setTitleColor(UIColor(white: 0.78, alpha: 1), for: .normal)
        diagnosticsButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        diagnosticsButton.addAction(UIAction { [weak self] _ in self?.onDiagnostics?() }, for: .touchUpInside)

        let passLabel = UILabel()
        passLabel.text = "Сквозное видео с камеры"
        passLabel.textColor = .white
        passLabel.font = .systemFont(ofSize: 13)
        passthroughSwitch.isOn = profile.passthrough
        passthroughSwitch.addAction(UIAction { [weak self] _ in self?.collect() }, for: .valueChanged)

        let passRow = UIStackView(arrangedSubviews: [passLabel, UIView(), passthroughSwitch])
        passRow.axis = .horizontal
        passRow.spacing = 12
        passRow.alignment = .center

        let resetButton = UIButton(type: .system)
        resetButton.setTitle("Сбросить калибровку", for: .normal)
        resetButton.setTitleColor(UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1), for: .normal)
        resetButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
        resetButton.contentHorizontalAlignment = .leading
        resetButton.addAction(UIAction { [weak self] _ in self?.resetProfile() }, for: .touchUpInside)

        stack.axis = .vertical
        stack.spacing = 14
        let ultraWideAvailable=UltraWideCapture.isAvailable
        let cameraMode=CameraMode.load(ultraWideAvailable:ultraWideAvailable)
        cameraSelector.setEnabled(ultraWideAvailable,forSegmentAt:0)
        cameraSelector.selectedSegmentIndex=cameraMode == .ultraWide ? 0 : 1
        cameraSelector.selectedSegmentTintColor=UIColor(white:0.7,alpha:0.35)
        cameraNote.font = .systemFont(ofSize:12)
        cameraNote.textColor=UIColor.white.withAlphaComponent(0.65)
        cameraNote.numberOfLines=0
        cameraSelector.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let mode: CameraMode=self.cameraSelector.selectedSegmentIndex == 0 ? .ultraWide : .worldTracking
            mode.save();self.updateCameraNote()
        },for:.valueChanged)
        updateCameraNote()
        stack.addArrangedSubview(cameraSelector)
        stack.addArrangedSubview(cameraNote)
        clickSelector.selectedSegmentIndex=HandClickMode.load() == .dwell ? 0 : 1
        clickSelector.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let mode: HandClickMode=self.clickSelector.selectedSegmentIndex == 0 ? .dwell : .pinch
            mode.save()
        },for:.valueChanged)
        stack.addArrangedSubview(clickSelector)
        aimSelector.selectedSegmentIndex = PointerControlMode.load() == .head ? 1 : 0
        aimSelector.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let mode: PointerControlMode = self.aimSelector.selectedSegmentIndex == 1 ? .head : .hand
            mode.save()
        }, for: .valueChanged)
        stack.addArrangedSubview(aimSelector)
        let clickNote=UILabel()
        clickNote.text="Отдых рук: поворачивай голову к кнопке и задержись на секунду. Режим можно сменить в VR → Настройки. Удержание: наведи указательный палец на кнопку на 1 секунду. Для повтора отведи курсор. Щипок с движением — прокрутка, кулак — захват панели."
        clickNote.font = .systemFont(ofSize:12);clickNote.textColor=UIColor.white.withAlphaComponent(0.65);clickNote.numberOfLines=0
        stack.addArrangedSubview(clickNote)

        // 3D-кинотеатр: поле для ссылки на YouTube + кнопка входа.
        let cinemaTitle = UILabel()
        cinemaTitle.text = "Кинотеатр"
        cinemaTitle.textColor = UIColor.white.withAlphaComponent(0.85)
        cinemaTitle.font = .systemFont(ofSize: 14, weight: .semibold)

        cinemaField.placeholder = "Ссылка на видео или прямой поток…"
        cinemaField.textColor = .white
        cinemaField.tintColor = .white
        cinemaField.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        cinemaField.layer.cornerRadius = 22
        cinemaField.borderStyle = .none
        cinemaField.keyboardType = .URL
        cinemaField.returnKeyType = .go
        cinemaField.autocapitalizationType = .none
        cinemaField.autocorrectionType = .no
        cinemaField.font = .systemFont(ofSize: 15)
        cinemaField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 0))
        cinemaField.leftViewMode = .always

        var cinemaConfig = UIButton.Configuration.filled()
        cinemaConfig.title = "Открыть кинотеатр"
        cinemaConfig.baseForegroundColor = .white
        cinemaConfig.baseBackgroundColor = UIColor(white: 0.32, alpha: 0.8)
        cinemaConfig.cornerStyle = .capsule
        cinemaButton.configuration = cinemaConfig
        cinemaButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cinemaButton.addAction(UIAction { [weak self] _ in
            self?.onCinema?(self?.cinemaField.text ?? "")
        }, for: .touchUpInside)
        cinemaField.addAction(UIAction { [weak self] _ in
            self?.onCinema?(self?.cinemaField.text ?? "")
        }, for: .editingDidEndOnExit)

        let cinemaSection = UIStackView(arrangedSubviews: [cinemaTitle, cinemaField, cinemaButton])
        cinemaSection.axis = .vertical
        cinemaSection.spacing = 8
        cinemaField.heightAnchor.constraint(equalToConstant: 44).isActive = true
        cinemaButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stack.addArrangedSubview(cinemaSection)

        let calibrationButton=UIButton(type:.system)
        var calibrationConfig=UIButton.Configuration.filled()
        calibrationConfig.title="Совместить изображения · VR BOX 3"
        calibrationConfig.baseBackgroundColor=UIColor(red:0.15,green:0.37,blue:0.48,alpha:1)
        calibrationConfig.baseForegroundColor = .white
        calibrationConfig.cornerStyle = .capsule
        calibrationButton.configuration=calibrationConfig
        calibrationButton.addAction(UIAction { [weak self] _ in self?.onCalibration?() },for:.touchUpInside)
        calibrationButton.heightAnchor.constraint(equalToConstant:46).isActive=true
        stack.addArrangedSubview(calibrationButton)
        let calibrationNote=UILabel()
        calibrationNote.text="Сначала расположи телефон по центру и настрой физические линзы. В калибровке добейся одного креста и круга. Щипок, удержание и контроллер работают. Объём между глазами отключён: справа копия левого кадра."
        calibrationNote.font = .systemFont(ofSize:12)
        calibrationNote.textColor=UIColor(white:0.8,alpha:1)
        calibrationNote.numberOfLines=0
        stack.addArrangedSubview(calibrationNote)
        for row in [lensRow, horizontalRow, verticalRow, verticalMatchRow, depthRow, k1Row, k2Row] {
            row.onChange = { [weak self] in self?.collect() }
            stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(passRow)
        stack.addArrangedSubview(resetButton)

        // Пять ползунков не помещаются в ландшафт по высоте, поэтому
        // блок калибровки прокручивается, а кнопка входа закреплена внизу.
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.indicatorStyle = .white

        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        for subview in [titleLabel, subtitleLabel, scrollView, enterButton, diagnosticsButton] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 40),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -40),
            scrollView.bottomAnchor.constraint(equalTo: enterButton.topAnchor, constant: -10),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            enterButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            enterButton.widthAnchor.constraint(equalToConstant: 230),
            enterButton.heightAnchor.constraint(equalToConstant: 46),
            enterButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -56),

            diagnosticsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            diagnosticsButton.heightAnchor.constraint(equalToConstant: 36),
            diagnosticsButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10)
        ])
    }

    func updatePointerControlMode() {
        aimSelector.selectedSegmentIndex = PointerControlMode.load() == .head ? 1 : 0
    }

    func setProfile(_ updated: VRProfile) {
        profile = updated
        applyProfile()
    }

    private func updateCameraNote() {
        if !UltraWideCapture.isAvailable { cameraNote.text="Камера 0,5× недоступна на этом iPhone. Работает обычный AR-режим." }
        else if cameraSelector.selectedSegmentIndex == 0 { cameraNote.text="Настоящая камера 0,5×. Повороты головы отслеживаются; перемещения по комнате — нет." }
        else { cameraNote.text="Обычная камера AR 1×: отслеживаются повороты и перемещения по комнате." }
    }

    func updateProfile(_ updated: VRProfile) {profile=updated;applyProfile()}

    private func applyProfile() {
        horizontalRow.value=profile.screenHorizontalOffsetMM ?? 0
        verticalRow.value=profile.lensVerticalOffsetMM
        verticalMatchRow.value=profile.rightEyeVerticalOffsetMM ?? 0
        ipdRow.value = profile.ipdMM
        lensRow.value = profile.lensSeparationMM
        depthRow.value = profile.eyeToScreenMM
        k1Row.value = profile.k1
        k2Row.value = profile.k2
        passthroughSwitch.isOn = profile.passthrough
    }

    private func collect() {
        profile.ipdMM = ipdRow.value
        profile.screenHorizontalOffsetMM=horizontalRow.value
        profile.lensVerticalOffsetMM=verticalRow.value
        profile.rightEyeVerticalOffsetMM=verticalMatchRow.value
        profile.lensSeparationMM = lensRow.value
        profile.eyeToScreenMM = depthRow.value
        profile.k1 = k1Row.value
        profile.k2 = k2Row.value
        profile.passthrough = passthroughSwitch.isOn
        profile.save()
        onProfileChange?(profile)
    }

    private func resetProfile() {
        var fresh = VRProfile.makeDefault()
        fresh.passthrough = profile.passthrough
        profile = fresh
        applyProfile()
        profile.save()
        onProfileChange?(profile)
    }
}

/// Подпись, значение, ползунок и пара кнопок точной подстройки.
final class SliderRow: UIView {
    var onChange: (() -> Void)?

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let minusButton = UIButton(type: .system)
    private let plusButton = UIButton(type: .system)
    private let unit: String
    private let step: Float

    var value: Float {
        get { slider.value }
        set {
            slider.value = min(max(newValue, slider.minimumValue), slider.maximumValue)
            refresh()
        }
    }

    init(title: String, unit: String, minimum: Float, maximum: Float, step: Float) {
        self.unit = unit
        self.step = step
        super.init(frame: .zero)

        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        valueLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        slider.minimumValue = minimum
        slider.maximumValue = maximum
        slider.minimumTrackTintColor = UIColor(red: 0.38, green: 0.78, blue: 1.0, alpha: 1)
        slider.isContinuous = true
        slider.addAction(UIAction { [weak self] _ in
            self?.refresh()
            self?.onChange?()
        }, for: .valueChanged)

        // Ползунком в 40 точек шириной точное значение не поймать,
        // поэтому рядом кнопки на один шаг.
        configureStepButton(minusButton, title: "−", delta: -step)
        configureStepButton(plusButton, title: "+", delta: step)

        let header = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        header.axis = .horizontal
        header.spacing = 8

        let controls = UIStackView(arrangedSubviews: [minusButton, slider, plusButton])
        controls.axis = .horizontal
        controls.spacing = 10
        controls.alignment = .center

        let container = UIStackView(arrangedSubviews: [header, controls])
        container.axis = .vertical
        container.spacing = 2
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            minusButton.widthAnchor.constraint(equalToConstant: 34),
            minusButton.heightAnchor.constraint(equalToConstant: 30),
            plusButton.widthAnchor.constraint(equalToConstant: 34),
            plusButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureStepButton(_ button: UIButton, title: String, delta: Float) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(white: 0.18, alpha: 1)
        button.layer.cornerRadius = 8
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.value = self.slider.value + delta
            self.onChange?()
        }, for: .touchUpInside)
    }

    private func refresh() {
        valueLabel.text = unit.isEmpty
            ? String(format: "%.3f", slider.value)
            : String(format: "%.1f %@", slider.value, unit)
    }
}


// MARK: - VR BOX controller bridge -------------------------------------------

enum VRBoxButton {
    case a, b, x, y, menu
}

final class VRBoxControllerService: NSObject {
    var onConnectionChanged: ((Bool, String) -> Void)?
    var onStick: ((CGFloat, CGFloat) -> Void)?
    var onButton: ((VRBoxButton, Bool) -> Void)?
    var onMotion: ((Bool, String) -> Void)?
    var onMotionSample: ((Bool, String) -> Void)?
    var onGyro: ((SIMD3<Float>) -> Void)?

    private var controllers: [GCController] = []
    private var attached = Set<ObjectIdentifier>()
    private var motionTimer: Timer?

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(didConnect(_:)), name: NSNotification.Name.GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didDisconnect(_:)), name: NSNotification.Name.GCControllerDidDisconnect, object: nil)
        for controller in GCController.controllers() { attach(controller) }
        publishStatus()
        startMotionPolling()
        pollMotion()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        motionTimer?.invalidate()
        motionTimer = nil
        controllers.removeAll()
        attached.removeAll()
    }

    private func startMotionPolling() {
        motionTimer?.invalidate()
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollMotion()
        }
        RunLoop.main.add(motionTimer!, forMode: .common)
    }

    private func pollMotion() {
        guard let motion = controllers.first?.motion else {
            onMotionSample?(false, "нет motion-профиля")
            return
        }
        if motion.hasRotationRate {
            let r = motion.rotationRate
            let vector = SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z))
            onGyro?(vector)
            onMotionSample?(true, String(format: "gyro x=%+.2f  y=%+.2f  z=%+.2f rad/s", r.x, r.y, r.z))
        } else if motion.hasAttitude {
            onMotionSample?(false, "attitude есть, rotation rate недоступен")
        } else if motion.hasGravityAndUserAcceleration {
            let a = motion.acceleration
            onMotionSample?(false, String(format: "accel x=%+.2f  y=%+.2f  z=%+.2f", a.x, a.y, a.z))
        } else {
            onMotionSample?(false, "motion-профиль есть, измерения не объявлены")
        }
    }

    @objc private func didConnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        attach(controller)
        publishStatus()
        pollMotion()
    }

    @objc private func didDisconnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        controllers.removeAll { $0 === controller }
        attached.remove(ObjectIdentifier(controller))
        publishStatus()
        pollMotion()
    }

    private func attach(_ controller: GCController) {
        let oid = ObjectIdentifier(controller)
        guard !attached.contains(oid) else { return }
        attached.insert(oid)
        controllers.append(controller)

        if let extended = controller.extendedGamepad {
            extended.valueChangedHandler = { [weak self] pad, element in
                guard let self else { return }
                let rawX = CGFloat(pad.leftThumbstick.xAxis.value)
                let rawY = CGFloat(pad.leftThumbstick.yAxis.value)
                if abs(rawX) > 0.03 || abs(rawY) > 0.03 {
                    self.onStick?(rawX, rawY)
                } else if element === pad.leftThumbstick.xAxis || element === pad.leftThumbstick.yAxis {
                    self.onStick?(0, 0)
                }
                if element === pad.buttonA { self.onButton?(.a, pad.buttonA.isPressed) }
                if element === pad.buttonB { self.onButton?(.b, pad.buttonB.isPressed) }
                if element === pad.buttonX { self.onButton?(.x, pad.buttonX.isPressed) }
                if element === pad.buttonY { self.onButton?(.y, pad.buttonY.isPressed) }
                if element === pad.buttonMenu { self.onButton?(.menu, pad.buttonMenu.isPressed) }
            }
        } else if let gamepad = controller.gamepad {
            gamepad.valueChangedHandler = { [weak self] pad, element in
                guard let self else { return }
                if element === pad.dpad.xAxis || element === pad.dpad.yAxis {
                    self.onStick?(CGFloat(pad.dpad.xAxis.value), CGFloat(pad.dpad.yAxis.value))
                }
                if element === pad.buttonA { self.onButton?(.a, pad.buttonA.isPressed) }
                if element === pad.buttonB { self.onButton?(.b, pad.buttonB.isPressed) }
                if element === pad.buttonX { self.onButton?(.x, pad.buttonX.isPressed) }
                if element === pad.buttonY { self.onButton?(.y, pad.buttonY.isPressed) }
            }
        }

        if let motion = controller.motion {
            var labels: [String] = []
            if motion.hasAttitude { labels.append("attitude") }
            if motion.hasRotationRate { labels.append("gyro") }
            if motion.hasGravityAndUserAcceleration { labels.append("accel") }
            onMotion?(motion.hasRotationRate, labels.joined(separator: ", ").isEmpty ? "motion: профиль есть" : labels.joined(separator: ", "))
        }
    }

    private func publishStatus() {
        let found = controllers.first
        let name = found?.vendorName ?? found?.productCategory ?? "Нет GameController"
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionChanged?(found != nil, name)
        }
    }
}

// MARK: - Диагностика VR BOX --------------------------------------------------

final class VRBoxDiagnosticsView: UIViewController {
    var onClose: (() -> Void)?

    private let service = VRBoxControllerService()
    private let status = UILabel()
    private let motion = UILabel()
    private let input = UILabel()
    private let log = UITextView()
    private let stickDot = UIView()
    private let stickPad = UIView()
    private var pointer = CGPoint(x: 0.5, y: 0.5)

    override func loadView() {
        view = UIView()
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        wire()
    }

    func startMonitoring() { service.start(); refresh() }

    private func build() {
        let title = UILabel()
        title.text = "VR BOX 3.0 • ДИАГНОСТИКА"
        title.textColor = .white
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textAlignment = .center

        for label in [status, motion, input] {
            label.textColor = UIColor.white.withAlphaComponent(0.82)
            label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            label.numberOfLines = 3
        }

        input.text = "Stick/Button: ждём события…"

        log.textColor = UIColor(white: 0.78, alpha: 1)
        log.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        log.layer.cornerRadius = 18
        log.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        log.isEditable = false
        log.isSelectable = false

        let close = UIButton(type: .system)
        close.setTitle("Закрыть", for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.backgroundColor = UIColor(white: 0.16, alpha: 1)
        close.layer.cornerRadius = 14
        close.addAction(UIAction { [weak self] _ in self?.service.stop(); self?.onClose?() }, for: .touchUpInside)

        stickPad.backgroundColor = UIColor(white: 0.12, alpha: 1)
        stickPad.layer.cornerRadius = 90
        stickPad.layer.borderWidth = 1
        stickPad.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        stickDot.backgroundColor = UIColor(red: 0.38, green: 0.86, blue: 1, alpha: 1)
        stickDot.layer.cornerRadius = 12
        stickPad.addSubview(stickDot)

        let stack = UIStackView(arrangedSubviews: [title, status, motion, input, stickPad, log, close])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            stickPad.heightAnchor.constraint(equalToConstant: 180),
            stickPad.widthAnchor.constraint(equalToConstant: 180),
            close.heightAnchor.constraint(equalToConstant: 46)
        ])
        stickPad.translatesAutoresizingMaskIntoConstraints = false
        stickPad.addConstraint(stickPad.widthAnchor.constraint(equalTo: stickPad.heightAnchor))
    }

    private func wire() {
        service.onConnectionChanged = { [weak self] connected, name in
            DispatchQueue.main.async {
                self?.status.text = connected ? "Bluetooth/GameController: ПОДКЛЮЧЕН\nУстройство: \(name)" : "Bluetooth/GameController: НЕ ВИДИТ\nУстройство: \(name)"
                self?.append("GameController: \(connected ? "connected" : "none") — \(name)")
            }
        }
        service.onMotion = { [weak self] hasGyro, detail in
            DispatchQueue.main.async {
                self?.motion.text = "Motion: \(hasGyro ? "GYRO ЕСТЬ" : "GYRO НЕ ОБНАРУЖЕН")\n\(detail)"
            }
        }
        service.onMotionSample = { [weak self] hasGyro, sample in
            DispatchQueue.main.async {
                guard let self else { return }
                let prefix = hasGyro ? "LIVE GYRO" : "LIVE MOTION"
                let current = self.motion.text ?? ""
                let base = current.components(separatedBy: "\nLIVE").first ?? current
                self.motion.text = base + "\n\(prefix): \(sample)"
            }
        }
        service.onStick = { [weak self] x, y in
            DispatchQueue.main.async {
                self?.pointer.x = min(max(0.5 + x * 0.5, 0), 1)
                self?.pointer.y = min(max(0.5 + y * 0.5, 0), 1)
                self?.input.text = String(format: "Stick: X=%+.2f  Y=%+.2f\nPointer: X=%.2f  Y=%.2f", x, y, self?.pointer.x ?? 0.5, self?.pointer.y ?? 0.5)
                self?.layoutStickDot()
                self?.append(String(format: "STICK  x=%+.2f  y=%+.2f", x, y))
            }
        }
        service.onButton = { [weak self] button, pressed in
            DispatchQueue.main.async {
                let name: String
                switch button { case .a: name="A"; case .b: name="B"; case .x: name="X"; case .y: name="Y"; case .menu: name="MENU" }
                self?.input.text = "BUTTON \(name): \(pressed ? "DOWN" : "UP")"
                self?.append("BUTTON \(name) \(pressed ? "DOWN" : "UP")")
            }
        }
        layoutStickDot()
    }

    private func refresh() {
        status.text = "Ищем контроллеры iOS…"
        motion.text = "Motion: ждём данные…"
        input.text = "Stick/Button: ждём события…"
        log.text = "Пошевели джойстик и нажми каждую кнопку.\n\n"
    }

    private func layoutStickDot() {
        let r = stickPad.bounds.width * 0.5 - 18
        let c = CGPoint(x: stickPad.bounds.midX + (pointer.x - 0.5) * r * 2,
                        y: stickPad.bounds.midY + (pointer.y - 0.5) * r * 2)
        stickDot.frame = CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)
    }

    private func append(_ line: String) {
        log.text.append(line + "\n")
        let range = NSRange(location: max(log.text.count - 1, 0), length: 1)
        log.scrollRangeToVisible(range)
    }

    deinit { service.stop() }
}
