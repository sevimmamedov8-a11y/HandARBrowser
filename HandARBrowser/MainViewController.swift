//
//  MainViewController.swift
//  HandAR Vision вЂ” V50
//
//  РЎС‚РµСЂРµРѕРєРѕРЅРІРµР№РµСЂ
//  РџРµСЂРµРґРЅРёР№ РїР»Р°РЅ: СЂРµР°Р»СЊРЅС‹Рµ РїРёРєСЃРµР»Рё СЂСѓРє РёР· РєР°РјРµСЂС‹ РєРѕРјРїРѕР·СЏС‚СЃСЏ РїРѕРІРµСЂС… Р±СЂР°СѓР·РµСЂР° РїРѕ РјР°СЃРєРµ Vision.
//  --------------
//    ARKit (РїРѕР·Р° РіРѕР»РѕРІС‹)
//        в””в”Ђв–є РѕРґРЅР° SCNScene, РґРІРµ РєР°РјРµСЂС‹ РЅР° СЂРµР°Р»СЊРЅРѕРј IPD
//              в””в”Ђв–є SCNRenderer Г— 2 в†’ РѕС„СЃРєСЂРёРЅ-С‚РµРєСЃС‚СѓСЂР° (Р»РµРІР°СЏ/РїСЂР°РІР°СЏ РїРѕР»РѕРІРёРЅР°)
//                    в””в”Ђв–є Metal: YCbCr-passthrough РїРµСЂ-РіР»Р°Р·, barrel-РїСЂРµРґС‹СЃРєР°Р¶РµРЅРёРµ,
//                        С…СЂРѕРјР°С‚РёРєР°, РјР°СЃРєР° Р»РёРЅР·С‹
//                          в””в”Ђв–є СЌРєСЂР°РЅ
//
//  РЈРїСЂР°РІР»РµРЅРёРµ
//  ----------
//    вЂў Р›СѓС‡ РІС‹С…РѕРґРёС‚ РёР· РєРѕРЅС‡РёРєР° СѓРєР°Р·Р°С‚РµР»СЊРЅРѕРіРѕ РїР°Р»СЊС†Р°. Р“РґРµ РѕРЅ РІСЃС‚СЂРµС‡Р°РµС‚ РїР°РЅРµР»СЊ,
//      С‚Р°Рј РіРѕСЂРёС‚ С‚РѕС‡РєР° СЃ РєРѕР»СЊС†РѕРј вЂ” РІРёРґРЅРѕ, РєСѓРґР° РЅР°РІРµРґС‘РЅ.
//    вЂў РќР°Р¶Р°С‚РёРµ: РЎР Р•Р”РќРР™ + Р±РѕР»СЊС€РѕР№ РїР°Р»РµС†.
//    вЂў РџРµСЂРµС‚Р°СЃРєРёРІР°РЅРёРµ РїР°РЅРµР»Рё: РЈРљРђР—РђРўР•Р›Р¬РќР«Р™ + Р±РѕР»СЊС€РѕР№, СЂСѓРєР° РІ РЅРёР¶РЅРµР№ С‚СЂРµС‚Рё РєР°РґСЂР°.
//    вЂў РњР°СЃС€С‚Р°Р±: РґРІРµ СЂСѓРєРё, СЃСЂРµРґРЅРёР№ + Р±РѕР»СЊС€РѕР№ РЅР° РєР°Р¶РґРѕР№; РґРІРёРіР°РµРј СѓРєР°Р·Р°С‚РµР»СЊРЅС‹Рµ
//      РґР°Р»СЊС€Рµ РґСЂСѓРі РѕС‚ РґСЂСѓРіР° вЂ” РѕРєРЅРѕ СѓРІРµР»РёС‡РёРІР°РµС‚СЃСЏ, Р±Р»РёР¶Рµ вЂ” СѓРјРµРЅСЊС€Р°РµС‚СЃСЏ.
//    вЂў РџР°РЅРµР»СЊ СЃСЃС‹Р»РѕРє РЅР°Рґ Р±СЂР°СѓР·РµСЂРѕРј: Google, YouTube, TikTok, РќР°Р·Р°Рґ.
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
    let indexTip: CGPoint
    let middleTip: CGPoint
    let thumbTip: CGPoint
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    /// РЎСЂРµРґРЅРёР№ + Р±РѕР»СЊС€РѕР№: РЅР°Р¶Р°С‚РёРµ.
    let clickPinch: Bool
    /// РЈРєР°Р·Р°С‚РµР»СЊРЅС‹Р№ + Р±РѕР»СЊС€РѕР№: Р·Р°С…РІР°С‚ РїР°РЅРµР»Рё.
    let grabPinch: Bool
    /// Р СѓРєР° РІ РєСѓР»Р°РєРµ вЂ” РїР°Р»СЊС†С‹ СЃРѕРіРЅСѓС‚С‹.
    let isFist: Bool
}

/// Р›СѓС‡ РІ РјРёСЂРѕРІС‹С… РєРѕРѕСЂРґРёРЅР°С‚Р°С….
struct WorldRay {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>

    func point(at distance: Float) -> SIMD3<Float> {
        origin + direction * distance
    }
}

// MARK: - РџСЂРѕС„РёР»СЊ С€Р»РµРјР° --------------------------------------------------------

/// Р¤РёР·РёРєР° С€Р»РµРјР° Рё Р»РёРЅР·. Р’СЃРµ Р»РёРЅРµР№РЅС‹Рµ СЂР°Р·РјРµСЂС‹ вЂ” РІ РјРёР»Р»РёРјРµС‚СЂР°С….
struct VRProfile: Codable, Equatable {
    /// РЁРёСЂРёРЅР° Р°РєС‚РёРІРЅРѕР№ РѕР±Р»Р°СЃС‚Рё СЌРєСЂР°РЅР° РІ Р»Р°РЅРґС€Р°С„С‚Рµ (РґР»РёРЅРЅР°СЏ СЃС‚РѕСЂРѕРЅР°).
    var screenWidthMM: Float
    /// Р’С‹СЃРѕС‚Р° Р°РєС‚РёРІРЅРѕР№ РѕР±Р»Р°СЃС‚Рё СЌРєСЂР°РЅР° РІ Р»Р°РЅРґС€Р°С„С‚Рµ (РєРѕСЂРѕС‚РєР°СЏ СЃС‚РѕСЂРѕРЅР°).
    var screenHeightMM: Float

    /// РњРµР¶Р·СЂР°С‡РєРѕРІРѕРµ СЂР°СЃСЃС‚РѕСЏРЅРёРµ РїРѕР»СЊР·РѕРІР°С‚РµР»СЏ.
    var ipdMM: Float = 63
    /// Р Р°СЃСЃС‚РѕСЏРЅРёРµ РјРµР¶РґСѓ С†РµРЅС‚СЂР°РјРё Р»РёРЅР· С€Р»РµРјР°.
    var lensSeparationMM: Float = 63
    /// РЎРјРµС‰РµРЅРёРµ С†РµРЅС‚СЂРѕРІ Р»РёРЅР· РїРѕ РІРµСЂС‚РёРєР°Р»Рё РѕС‚РЅРѕСЃРёС‚РµР»СЊРЅРѕ С†РµРЅС‚СЂР° СЌРєСЂР°РЅР°.
    var lensVerticalOffsetMM: Float = 0
    /// Р Р°СЃСЃС‚РѕСЏРЅРёРµ РѕС‚ РіР»Р°Р·Р° РґРѕ СЌРєСЂР°РЅР° СЃРєРІРѕР·СЊ Р»РёРЅР·Сѓ.
    var eyeToScreenMM: Float = 42

    /// РљРѕСЌС„С„РёС†РёРµРЅС‚С‹ СЂР°РґРёР°Р»СЊРЅРѕРіРѕ РїСЂРµРґС‹СЃРєР°Р¶РµРЅРёСЏ.
    var k1: Float = 0.0
    var k2: Float = 0.0
    /// Р‘РµР· РёСЃРєСѓСЃСЃС‚РІРµРЅРЅРѕР№ С…СЂРѕРјР°С‚РёРєРё: РєР°СЂС‚РёРЅРєР° Р·Р°РїРѕР»РЅСЏРµС‚ РІРµСЃСЊ СЌРєСЂР°РЅ.
    var chroma: Float = 0.0
    /// РЎРѕС…СЂР°РЅСЏРµС‚СЃСЏ РґР»СЏ СЃРѕРІРјРµСЃС‚РёРјРѕСЃС‚Рё РїСЂРѕС„РёР»СЏ; С„Р°РєС‚РёС‡РµСЃРєРёР№ СЂР°РґРёСѓСЃ РєСЂСѓРіР»РѕР№
    /// Р»РёРЅР·С‹ РІС‹С‡РёСЃР»СЏРµС‚СЃСЏ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё РїРѕ СЂР°Р·РјРµСЂСѓ СЌРєСЂР°РЅР°.
    var lensClipRadius: Float = 0.0

    /// Р—Р°РїР°СЃ РїРѕР»СЏ Р·СЂРµРЅРёСЏ РїРѕРґ РїСЂРµРґС‹СЃРєР°Р¶РµРЅРёРµ. Р‘РѕР»СЊС€Рµ вЂ” РєР°СЂС‚РёРЅРєР° РїР»РѕС‚РЅРµРµ
    /// Р·Р°РїРѕР»РЅСЏРµС‚ РєСЂСѓРіР»СѓСЋ Р»РёРЅР·Сѓ, РјРµРЅСЊС€Рµ С‡С‘СЂРЅС‹С… РїРѕР»РµР№ РїРѕ РєСЂР°СЋ.
    var fovScale: Float = 1.0
    /// РЎСѓРїРµСЂСЃСЌРјРїР»РёРЅРі РѕС„СЃРєСЂРёРЅ-Р±СѓС„РµСЂР°.
    var supersample: Float = 1.2

    /// РЎРєРІРѕР·РЅРѕРµ РІРёРґРµРѕ СЃ РєР°РјРµСЂС‹.
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
        // SE-РєРѕСЂРїСѓСЃР° вЂ” 326 ppi, РѕСЃС‚Р°Р»СЊРЅС‹Рµ СЃРѕРІСЂРµРјРµРЅРЅС‹Рµ iPhone вЂ” РѕРєРѕР»Рѕ 460.
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
            let decoded = try? JSONDecoder().decode(VRProfile.self, from: data)
        else {
            return makeDefault()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: VRProfile.storageKey)
    }
}

/// Р“СЂР°РЅРёС†С‹ РїРёСЂР°РјРёРґС‹ РІРёРґРёРјРѕСЃС‚Рё РЅР° РµРґРёРЅРёС‡РЅРѕРј СЂР°СЃСЃС‚РѕСЏРЅРёРё (С‚Р°РЅРіРµРЅСЃС‹ СѓРіР»РѕРІ).
struct EyeFrustum {
    var left: Float
    var right: Float
    var bottom: Float
    var top: Float
}

enum VRLensMath {
    /// РЎРёРјРјРµС‚СЂРёС‡РЅС‹Р№ С„СЂСѓСЃС‚СѓРј: Р»РµРІС‹Р№ Рё РїСЂР°РІС‹Р№ РіР»Р°Р· РїРѕР»СѓС‡Р°СЋС‚ РѕРґРёРЅР°РєРѕРІСѓСЋ
    /// С€РёСЂРёРЅСѓ Рё РѕРґРёРЅР°РєРѕРІС‹Р№ РіРѕСЂРёР·РѕРЅС‚Р°Р»СЊРЅС‹Р№ FOV. РњРµР¶Р·СЂР°С‡РєРѕРІРѕРµ СЂР°СЃСЃС‚РѕСЏРЅРёРµ
    /// РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ С‚РѕР»СЊРєРѕ РґР»СЏ СЂР°Р·РЅРµСЃРµРЅРёСЏ РєР°РјРµСЂ, Р° РЅРµ РґР»СЏ СЃРґРІРёРіР° РєР°СЂС‚РёРЅРєРё
    /// РІРЅСѓС‚СЂРё СЃРІРѕРµР№ РїРѕР»РѕРІРёРЅС‹ СЌРєСЂР°РЅР°. Р­С‚Рѕ СѓСЃС‚СЂР°РЅСЏРµС‚ РЅРµСЂР°РІРЅРѕРјРµСЂРЅРѕРµ СЃРІРµРґРµРЅРёРµ
    /// РґРІСѓС… РёР·РѕР±СЂР°Р¶РµРЅРёР№ РїРѕРґ С„РёР·РёС‡РµСЃРєРёРµ Р»РёРЅР·С‹ С€Р»РµРјР°.
    static func frustum(eye: Int, profile: VRProfile) -> EyeFrustum {
        _ = eye
        let halfEyeWidth = profile.screenWidthMM * 0.25
        let halfHeight = profile.screenHeightMM * 0.5
        let depth = max(profile.eyeToScreenMM, 1)
        let lensY = profile.lensVerticalOffsetMM

        var frustum = EyeFrustum(left: -halfEyeWidth / depth,
                                 right: halfEyeWidth / depth,
                                 bottom: (-halfHeight - lensY) / depth,
                                 top: (halfHeight - lensY) / depth)

        // Р РµРЅРґРµСЂРёРј С€РёСЂРµ РІРёРґРёРјРѕРіРѕ: РїСЂРµРґС‹СЃРєР°Р¶РµРЅРёРµ СѓС‚СЏРіРёРІР°РµС‚ РєСЂР°СЏ Рє С†РµРЅС‚СЂСѓ.
        let scale = max(profile.fovScale, 1)
        let centerX = (frustum.left + frustum.right) * 0.5
        let centerY = (frustum.bottom + frustum.top) * 0.5
        frustum.left = centerX + (frustum.left - centerX) * scale
        frustum.right = centerX + (frustum.right - centerX) * scale
        frustum.bottom = centerY + (frustum.bottom - centerY) * scale
        frustum.top = centerY + (frustum.top - centerY) * scale
        return frustum
    }

    /// Р¦РµРЅС‚СЂ РєР°Р¶РґРѕР№ Р»РёРЅР·С‹ РІСЃРµРіРґР° РЅР°С…РѕРґРёС‚СЃСЏ РІ С†РµРЅС‚СЂРµ СЃРІРѕРµР№ РїРѕР»РѕРІРёРЅС‹ РґРёСЃРїР»РµСЏ.
    /// РџРѕСЌС‚РѕРјСѓ Р»РµРІРѕРµ Рё РїСЂР°РІРѕРµ РёР·РѕР±СЂР°Р¶РµРЅРёСЏ РёРјРµСЋС‚ РѕРґРёРЅР°РєРѕРІСѓСЋ РіРµРѕРјРµС‚СЂРёСЋ Рё
    /// РЅРµ СЂР°СЃС…РѕРґСЏС‚СЃСЏ РїРѕ РіРѕСЂРёР·РѕРЅС‚Р°Р»Рё.
    static func lensCenterUV(eye: Int, profile: VRProfile) -> SIMD2<Float> {
        _ = eye
        return SIMD2<Float>(0.5,
                            0.5 - profile.lensVerticalOffsetMM / max(profile.screenHeightMM, 1))
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

// MARK: - Metal-РєРѕРјРїРѕР·РёС‚РѕСЂ -----------------------------------------------------

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
}

/// Р¤РёРЅР°Р»СЊРЅС‹Р№ РїСЂРѕС…РѕРґ. Р‘РµСЂС‘С‚ РѕС„СЃРєСЂРёРЅ-С‚РµРєСЃС‚СѓСЂСѓ РіР»Р°Р· (Р»РµРІС‹Р№ РіР»Р°Р· СЃР»РµРІР°, РїСЂР°РІС‹Р№ СЃРїСЂР°РІР°),
/// РїРѕРґРєР»Р°РґС‹РІР°РµС‚ РїРѕРґ РЅРµС‘ СЃРєРІРѕР·РЅРѕРµ РІРёРґРµРѕ СЃ РєР°РјРµСЂС‹ Рё РїСЂРѕРґР°РІР»РёРІР°РµС‚ РІСЃС‘ С‡РµСЂРµР· РѕРїС‚РёРєСѓ Р»РёРЅР·.
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

        // РР·РѕС‚СЂРѕРїРЅРѕРµ РїСЂРѕСЃС‚СЂР°РЅСЃС‚РІРѕ Р»РёРЅР·С‹.
        float2 p = (eyeUV - center) * float2(u.aspect, 1.0);
        float r2 = dot(p, p);
        float r = sqrt(r2);
        if (u.rClip < 5.0 && r > u.rClip) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        // РџСЂРµРґС‹СЃРєР°Р¶РµРЅРёРµ: Р±РµСЂС‘Рј РёСЃС‚РѕС‡РЅРёРє РґР°Р»СЊС€Рµ РѕС‚ С†РµРЅС‚СЂР°, С‡С‚РѕР±С‹ Р»РёРЅР·Р°,
        // СЂР°СЃС‚СЏРіРёРІР°СЋС‰Р°СЏ РєР°СЂС‚РёРЅРєСѓ РЅР°СЂСѓР¶Сѓ, РІРµСЂРЅСѓР»Р° РїСЂСЏРјС‹Рµ Р»РёРЅРёРё РїСЂСЏРјС‹РјРё.
        float f = 1.0 + u.k1 * r2 + u.k2 * r2 * r2;
        float2 inv = float2(1.0 / u.aspect, 1.0);
        float2 sampleG = center + p * f * inv;
        float2 sampleR = center + p * (f * (1.0 + u.chroma)) * inv;
        float2 sampleB = center + p * (f * (1.0 - u.chroma)) * inv;

        if (sampleG.x < 0.0 || sampleG.x > 1.0 || sampleG.y < 0.0 || sampleG.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        float2 off = float2(eye * 0.5, 0.0);
        float4 cg = eyes.sample(smp, float2(sampleG.x * 0.5, sampleG.y) + off);
        float cr = eyes.sample(smp, float2(sampleR.x * 0.5, sampleR.y) + off).r;
        float cb = eyes.sample(smp, float2(sampleB.x * 0.5, sampleB.y) + off).b;

        float3 overlay = float3(cr, cg.g, cb);
        float alpha = cg.a;

        float3 background = float3(0.0);
        float2 camUV = float2(-1.0);
        bool validCamUV = false;
        if (u.passthrough > 0.5) {
            float2 camScale = (eye < 0.5) ? u.camScaleL : u.camScaleR;
            float2 camOffset = (eye < 0.5) ? u.camOffsetL : u.camOffsetR;
            camUV = sampleG * camScale + camOffset;
            validCamUV = camUV.x >= 0.0 && camUV.x <= 1.0 && camUV.y >= 0.0 && camUV.y <= 1.0;
            if (validCamUV) {
                float yy = camY.sample(smp, camUV).r;
                float2 cc = camCbCr.sample(smp, camUV).rg;
                background = clamp(ycbcr_to_rgb(yy, cc), 0.0, 1.0);
            }
        }

        float3 color = mix(background, overlay, clamp(alpha, 0.0, 1.0));

        // Р РµР°Р»СЊРЅС‹Р№ РїРµСЂРµРґРЅРёР№ РїР»Р°РЅ СЂСѓРєРё: РјР°СЃРєР° Р·Р°РґР°С‘С‚СЃСЏ Vision, С†РІРµС‚ Р±РµСЂС‘С‚СЃСЏ
        // РЅРµРїРѕСЃСЂРµРґСЃС‚РІРµРЅРЅРѕ РёР· С‚РµРєСѓС‰РµРіРѕ РєР°РґСЂР° РєР°РјРµСЂС‹, РїРѕСЌС‚РѕРјСѓ СЂСѓРєР° РЅР°С…РѕРґРёС‚СЃСЏ
        // РїРѕРІРµСЂС… РІРёСЂС‚СѓР°Р»СЊРЅРѕРіРѕ Р±СЂР°СѓР·РµСЂР° Р±РµР· РЅР°СЂРёСЃРѕРІР°РЅРЅРѕРіРѕ СЃРєРµР»РµС‚Р°.
        if (u.handMaskEnabled > 0.5 && validCamUV) {
            float handAlpha = handMask.sample(smp, camUV).r;
            if (handAlpha > 0.01) {
                float yyHand = camY.sample(smp, camUV).r;
                float2 ccHand = camCbCr.sample(smp, camUV).rg;
                float3 handColor = clamp(ycbcr_to_rgb(yyHand, ccHand), 0.0, 1.0);
                color = mix(color, handColor, handAlpha);
            }
        }

        // РњСЏРіРєРёР№ РєСЂР°Р№ РёРјРµРЅРЅРѕ РєСЂСѓРіР»РѕР№ Р»РёРЅР·С‹: РІРЅСѓС‚СЂРё РєСЂСѓРіР° 100%, РЅР°
        // РїРѕСЃР»РµРґРЅРёС… ~0.008 РµРґРёРЅРёС†С‹ РїР»Р°РІРЅРѕ СѓС…РѕРґРёРј РІ С‡С‘СЂРЅС‹Р№.
        float vignette = 1.0;
        if (u.rClip < 5.0) {
            float softEdge = max(u.rClip - 0.008, 0.0);
            vignette = 1.0 - smoothstep(softEdge, u.rClip, r);
        }
        return float4(color * vignette, 1.0);
    }
    """

    private func makePipeline() -> Bool {
        do {
            // РљРѕРјРїРёР»СЏС†РёСЏ РІ СЂР°РЅС‚Р°Р№РјРµ: РЅРµ С‚СЂРµР±СѓРµС‚ .metal-С„Р°Р№Р»Р° РІ РїСЂРѕРµРєС‚Рµ.
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
            NSLog("VRCompositor: С€РµР№РґРµСЂ РЅРµ СЃРѕР±СЂР°Р»СЃСЏ вЂ” \(error)")
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

// MARK: - РџР°РЅРµР»СЊ СЃСЃС‹Р»РѕРє --------------------------------------------------------

/// РљРЅРѕРїРєР° РЅР° РїР»Р°РЅРєРµ РЅР°Рґ Р±СЂР°СѓР·РµСЂРѕРј.
struct ToolbarItem {
    enum Action {
        case open(URL)
        case back
        case home
        case center
    }

    let title: String
    let action: Action
    /// Р“СЂР°РЅРёС†С‹ РїРѕ Р»РѕРєР°Р»СЊРЅРѕР№ РѕСЃРё X РїР°РЅРµР»Рё, РІ РјРµС‚СЂР°С… РѕС‚ РµС‘ С†РµРЅС‚СЂР°.
    var minX: Float = 0
    var maxX: Float = 0
}

// MARK: - Р“Р»Р°РІРЅС‹Р№ РєРѕРЅС‚СЂРѕР»Р»РµСЂ ---------------------------------------------------

final class MainViewController: UIViewController, MTKViewDelegate {
    private let tracking = ARStereoTrackingManager()
    private let hands = HandTracker()
    private let input = WebInputBridge()
    private let controller = VRBoxControllerService()

    // РћРґРЅР° Р»РѕРіРёС‡РµСЃРєР°СЏ РїРѕРІРµСЂС…РЅРѕСЃС‚СЊ Р±СЂР°СѓР·РµСЂР°. РЎС‚РµСЂРµРѕ СЂРѕР¶РґР°РµС‚СЃСЏ РёР· РґРІСѓС… РєР°РјРµСЂ,
    // Р° РЅРµ РёР· РґРІСѓС… РєРѕРїРёР№ СЃС‚СЂР°РЅРёС†С‹.
    private let browser: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        // Р’РёРґРµРѕ РЅРµ РґРѕР»Р¶РЅРѕ СѓС…РѕРґРёС‚СЊ РёР· WKWebView РІ РѕС‚РґРµР»СЊРЅС‹Р№ СЃРёСЃС‚РµРјРЅС‹Р№
        // fullscreen-РєРѕРЅС‚СЂРѕР»Р»РµСЂ: РѕРЅРѕ РѕСЃС‚Р°С‘С‚СЃСЏ С‡Р°СЃС‚СЊСЋ СЃС‚СЂР°РЅРёС†С‹ Рё РїРѕРїР°РґР°РµС‚
        // РІ С‚РѕС‚ Р¶Рµ СЃС‚РµСЂРµРѕ-VR-РєРѕРјРїРѕР·РёС‚РѕСЂ.
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
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.scrollView.alwaysBounceVertical = true
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        return webView
    }()
    private var browserTimer: Timer?
    private var snapshotInProgress = false

    // РўРµС…РЅРѕР»РѕРіРёС‡РµСЃРєРёР№ РѕР±С…РѕРґ С‡С‘СЂРЅРѕРіРѕ YouTube-video: Р°РїРїР°СЂР°С‚РЅС‹Р№ HTML5 video
    // РЅРµ РїРѕРїР°РґР°РµС‚ РІ WKWebView.takeSnapshot, РїРѕСЌС‚РѕРјСѓ РІ РєРёРЅРѕСЂРµР¶РёРјРµ РёСЃРїРѕР»СЊР·СѓРµРј
    // РґРІР° РЅР°СЃС‚РѕСЏС‰РёС… РІРёРґРёРјС‹С… WKWebView вЂ” РїРѕ РѕРґРЅРѕРјСѓ РЅР° РєР°Р¶РґСѓСЋ VR-Р»РёРЅР·Сѓ.
    private let directVideoStage = UIView(frame: .zero)
    private var directVideoLeft: WKWebView!
    private var directVideoRight: WKWebView!
    private let directVideoLensMask = DirectVideoLensMaskView(frame: .zero)
    private let directVideoPointer = UIView(frame: .zero)
    private var directVideoActive = false
    private var directVideoURL: URL?
    private var directVideoSyncTimer: Timer?
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

    // CPU-РјР°СЃРєР° РєРёСЃС‚Рё. РЁРµР№РґРµСЂ РёСЃРїРѕР»СЊР·СѓРµС‚ РµС‘ С‚РѕР»СЊРєРѕ РєР°Рє Р°Р»СЊС„Р°-РјР°С‚С‚РёРЅРі РґР»СЏ
    // РЅР°СЃС‚РѕСЏС‰РµРіРѕ РёР·РѕР±СЂР°Р¶РµРЅРёСЏ РєР°РјРµСЂС‹, РїРѕСЌС‚РѕРјСѓ СЂСѓРєРё РІС‹РіР»СЏРґСЏС‚ РЅР°С‚СѓСЂР°Р»СЊРЅРѕ.
    private let handMaskWidth = 320
    private let handMaskHeight = 320
    private var handMaskTexture: MTLTexture?
    private let handMaskLock = NSLock()
    private var pendingHandMaskBytes = [UInt8]()
    private var pendingHandMaskActive = false

    // РЎС†РµРЅР°: РѕРґРЅР° РЅР° РѕР±Р° РіР»Р°Р·Р°
    private let worldScene = SCNScene()
    private var leftRenderer: SCNRenderer!
    private var rightRenderer: SCNRenderer!
    private let headNode = SCNNode()
    private let leftCameraNode = SCNNode()
    private let rightCameraNode = SCNNode()
    private let browserPlaneNode = SCNNode()
    private let browserMaterial = SCNMaterial()

    // РЈРєР°Р·Р°С‚РµР»СЊ: Р»СѓС‡ РёР· РїР°Р»СЊС†Р° РїР»СЋСЃ С‚РѕС‡РєР° СЃ РєРѕР»СЊС†РѕРј РІ РјРµСЃС‚Рµ РїРѕРїР°РґР°РЅРёСЏ.
    private let rayNode = SCNNode()
    private let pointerNode = SCNNode()
    private let pointerDotNode = SCNNode()
    private let pointerRingNode = SCNNode()

    // РЎРєРµР»РµС‚С‹ СЂСѓРє РЅР°С…РѕРґСЏС‚СЃСЏ РІ С‚РѕР№ Р¶Рµ РјРёСЂРѕРІРѕР№ СЃС†РµРЅРµ, РЅРѕ РёРјРµСЋС‚ РІС‹СЃРѕРєРёР№
    // renderingOrder Рё РѕС‚РєР»СЋС‡С‘РЅРЅС‹Р№ depth test вЂ” РїРѕСЌС‚РѕРјСѓ РѕРЅРё РІСЃРµРіРґР° РїРѕРІРµСЂС… РїР°РЅРµР»Рё.
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

    // РџР»Р°РЅРєР° СЃСЃС‹Р»РѕРє РЅР°Рґ Р±СЂР°СѓР·РµСЂРѕРј.
    private let toolbarNode = SCNNode()
    private var linkItems: [ToolbarItem] = []
    private var toolbarButtonNodes: [SCNNode] = []
    private var toolbarCenterY: Float = 0
    private let toolbarButtonHeight: Float = 0.072
    private var highlightedToolbarIndex: Int?

    private var menu: MainMenuView!
    private var diagnosticsView: VRBoxDiagnosticsView?

    private var profile = VRProfile.load()
    private var inVR = false
    private var securityGameActive = false
    private let securityGame = SecurityVRGame()
    private var browserAnchor: ARAnchor?
    private var browserWorldTransform: simd_float4x4?
    private var didCreateInitialAnchor = false

    // РџРµСЂРµС‚Р°СЃРєРёРІР°РЅРёРµ РїР°РЅРµР»Рё
    private var isDragging = false
    private var dragDistance: Float = 1.55
    private var dragOffset = SIMD3<Float>(repeating: 0)
    private var wasClickPinching = false
    private var controllerPointer = CGPoint(x: 0.5, y: 0.5)
    private var controllerButtonDown = false
    private var controllerConnected = false
    private var lastHandSeenTime: CFTimeInterval = 0
    private var controllerHandEuler = SIMD3<Float>(repeating: 0)
    private var controllerMotionAvailable = false
    private var controllerMotionRotation = SIMD3<Float>(repeating: 0)

    // РњР°СЃС€С‚Р°Р±РёСЂРѕРІР°РЅРёРµ РґРІСѓРјСЏ СЂСѓРєР°РјРё: РѕР±Рµ СЂСѓРєРё РґРµР»Р°СЋС‚ СЃСЂРµРґРЅРёР№+Р±РѕР»СЊС€РѕР№ РїР°Р»РµС†,
    // Р·Р°С‚РµРј СЂР°СЃСЃС‚РѕСЏРЅРёРµ РјРµР¶РґСѓ РєРѕРЅС‡РёРєР°РјРё СѓРєР°Р·Р°С‚РµР»СЊРЅС‹С… РјРµРЅСЏРµС‚ СЂР°Р·РјРµСЂ РїР°РЅРµР»Рё.
    private var isResizing = false
    private var resizeStartHandDistance: CGFloat = 0
    private var resizeStartWidth: Float = MainViewController.defaultPanelWidth

    // РџР°РЅРµР»СЊ Р±СЂР°СѓР·РµСЂР° РІ РјРёСЂРµ. Р Р°Р·РјРµСЂ Р±РѕР»СЊС€РѕР№ РЅР°РјРµСЂРµРЅРЅРѕ: РїР°РЅРµР»СЊ СЂР°Р·РјРµСЂРѕРј
    // СЃ РїРѕС‡С‚РѕРІС‹Р№ РєРѕРЅРІРµСЂС‚ РЅР° СЂР°СЃСЃС‚РѕСЏРЅРёРё РІС‹С‚СЏРЅСѓС‚РѕР№ СЂСѓРєРё Р·Р°РЅРёРјР°РµС‚ Р¶Р°Р»РєСѓСЋ С‡Р°СЃС‚СЊ
    // РїРѕР»СЏ Р·СЂРµРЅРёСЏ Рё РІС‹РіР»СЏРґРёС‚ РєР°Рє РјР°Р»РµРЅСЊРєРёР№ РєРІР°РґСЂР°С‚ РїРѕСЃСЂРµРґРё С‡РµСЂРЅРѕС‚С‹. Р—РґРµСЃСЊ
    // РїР°РЅРµР»СЊ РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ вЂ” СЌС‚Рѕ СѓР¶Рµ В«Р±РѕР»СЊС€РѕР№ РјРѕРЅРёС‚РѕСЂВ», Р° РЅРµ РѕРєРѕС€РєРѕ.
    private static let defaultPanelWidth: Float = 2.90
    private static let defaultPanelHeight: Float = 1.63
    private static let minimumPanelWidth: Float = 0.72
    private static let maximumPanelWidth: Float = 3.80
    private static let defaultPanelAspect: Float = defaultPanelHeight / defaultPanelWidth
    /// Р’РёРґРµРѕ РЅР° YouTube/TikTok СЂР°Р·РІРѕСЂР°С‡РёРІР°РµС‚СЃСЏ РІ В«РєРёРЅРѕР·Р°Р»В»: СЌРєСЂР°РЅ Р·Р°РЅРёРјР°РµС‚
    /// Р±РѕР»СЊС€СѓСЋ С‡Р°СЃС‚СЊ РїРѕР»СЏ Р·СЂРµРЅРёСЏ С€Р»РµРјР°, РїРѕС‡С‚Рё РєР°Рє РІ РЅР°СЃС‚РѕСЏС‰РµРј VR-РєРёРЅРѕС‚РµР°С‚СЂРµ.
    private static let cinemaPanelWidth: Float = 3.15
    private static let cinemaPanelHeight: Float = 1.77
    private var browserWorldWidth: Float = MainViewController.defaultPanelWidth
    private var browserWorldHeight: Float = MainViewController.defaultPanelHeight
    private let browserWorldDistance: Float = 1.65
    private var isCinemaMode = false
    private var browserPlaneGeometry: SCNPlane!
    private var browserFrameGeometry: SCNBox!
    private var browserHandleNode: SCNNode!
    /// РќРёР¶Рµ СЌС‚РѕР№ РґРѕР»Рё РєР°РґСЂР° С‰РёРїРѕРє СѓРєР°Р·Р°С‚РµР»СЊРЅС‹Рј СЃС‡РёС‚Р°РµС‚СЃСЏ Р·Р°С…РІР°С‚РѕРј РїР°РЅРµР»Рё.
    private let dragZoneHeight: CGFloat = 0.34
    /// РќР° С‚Р°РєРѕРј СЂР°СЃСЃС‚РѕСЏРЅРёРё РѕС‚ РєР°РјРµСЂС‹ СЂРёСЃСѓРµС‚СЃСЏ РЅР°С‡Р°Р»Рѕ Р»СѓС‡Р° вЂ” РїСЂРёРјРµСЂРЅРѕ С‚Р°Рј РєРёСЃС‚СЊ.
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

    // MARK: Р–РёР·РЅРµРЅРЅС‹Р№ С†РёРєР»

    override func viewDidLoad() {
        super.viewDidLoad()
        UIDevice.current.isBatteryMonitoringEnabled = true
        view.backgroundColor = .black
        configureMetal()
        configureScene()
        configureBrowser()
        buildInterface()
        wireServices()
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
        browserTimer?.invalidate()
        directVideoSyncTimer?.invalidate()
        removeDirectVideoMessageHandlers()
        if mediaAudioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        // WKUserContentController РґРµСЂР¶РёС‚ РѕР±СЂР°Р±РѕС‚С‡РёРє СЃРёР»СЊРЅРѕР№ СЃСЃС‹Р»РєРѕР№ вЂ”
        // Р±РµР· СЏРІРЅРѕРіРѕ СЃРЅСЏС‚РёСЏ РїРѕР»СѓС‡РёР»СЃСЏ Р±С‹ С†РёРєР» СЂРµС‚РµР№РЅРѕРІ.
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "handarVideo")
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "handarApp")
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "handarSystem")
        controller.stop()
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }

    // MARK: РЎР±РѕСЂРєР°

    private func configureMetal() {
        guard
            let metalDevice = MTLCreateSystemDefaultDevice(),
            let queue = metalDevice.makeCommandQueue()
        else {
            showAlert("Metal РЅРµРґРѕСЃС‚СѓРїРµРЅ РЅР° СЌС‚РѕРј СѓСЃС‚СЂРѕР№СЃС‚РІРµ.")
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
        rightRenderer = SCNRenderer(device: metalDevice, options: nil)
        for renderer in [leftRenderer, rightRenderer] {
            renderer?.scene = worldScene
            renderer?.autoenablesDefaultLighting = false
            renderer?.isJitteringEnabled = false
        }
    }

    private func configureScene() {
        // Р¤РѕРЅ СЃС†РµРЅС‹ РїСЂРѕР·СЂР°С‡РЅС‹Р№: СЃРєРІРѕР·РЅРѕРµ РІРёРґРµРѕ РїРѕРґРєР»Р°РґС‹РІР°РµС‚ РєРѕРјРїРѕР·РёС‚РѕСЂ,
        // РѕС‚РґРµР»СЊРЅРѕ РґР»СЏ РєР°Р¶РґРѕРіРѕ РіР»Р°Р·Р° Рё СЃ СѓС‡С‘С‚РѕРј РµРіРѕ С„СЂСѓСЃС‚СѓРјР°.
        worldScene.background.contents = UIColor.clear

        let leftCamera = SCNCamera()
        leftCamera.zNear = 0.02
        leftCamera.zFar = 100
        leftCameraNode.camera = leftCamera

        let rightCamera = SCNCamera()
        rightCamera.zNear = 0.02
        rightCamera.zFar = 100
        rightCameraNode.camera = rightCamera

        headNode.addChildNode(leftCameraNode)
        headNode.addChildNode(rightCameraNode)
        worldScene.rootNode.addChildNode(headNode)
        applyEyeGeometry()

        buildBrowserPanel()
        buildToolbar()
        buildPointer()
        buildControllerHand()
        // 3D-СЃРєРµР»РµС‚ Р±РѕР»СЊС€Рµ РЅРµ РїРѕРєР°Р·С‹РІР°РµРј: РїРѕРІРµСЂС… Р±СЂР°СѓР·РµСЂР° РІС‹РІРѕРґРёРј РЅР°СЃС‚РѕСЏС‰РёРµ
        // РїРёРєСЃРµР»Рё СЂСѓРєРё РёР· РєР°РјРµСЂС‹ С‡РµСЂРµР· handMaskTexture.
    }

    private func buildBrowserPanel() {
        let geometry = SCNPlane(
            width: CGFloat(browserWorldWidth),
            height: CGFloat(browserWorldHeight)
        )
        geometry.widthSegmentCount = 1
        geometry.heightSegmentCount = 1

        browserMaterial.lightingModel = .constant
        browserMaterial.isDoubleSided = true
        browserMaterial.diffuse.contents = UIColor.black
        browserMaterial.emission.contents = UIColor.black
        browserMaterial.specular.contents = UIColor.black
        browserMaterial.diffuse.wrapS = .clamp
        browserMaterial.diffuse.wrapT = .clamp
        browserMaterial.shininess = 0
        geometry.firstMaterial = browserMaterial
        browserPlaneGeometry = geometry

        browserPlaneNode.geometry = geometry
        browserPlaneNode.isHidden = true
        worldScene.rootNode.addChildNode(browserPlaneNode)

        // Р Р°РјРєР°: РјРѕР·РіСѓ РЅСѓР¶РµРЅ РєСЂР°Р№, С‡С‚РѕР±С‹ Р·Р°С†РµРїРёС‚СЊСЃСЏ Р·Р° РіР»СѓР±РёРЅСѓ РїР°РЅРµР»Рё.
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
        let frameNode = SCNNode(geometry: frameGeometry)
        frameNode.position = SCNVector3(0, 0, -0.005)
        browserPlaneNode.addChildNode(frameNode)

        // Р СѓС‡РєР° РІРЅРёР·Сѓ вЂ” РїРѕРґСЃРєР°Р·РєР°, Р·Р° С‡С‚Рѕ С‚СЏРЅСѓС‚СЊ.
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

    /// РџРµСЂРµРєР»СЋС‡Р°РµС‚ Р±СЂР°СѓР·РµСЂ РјРµР¶РґСѓ РѕР±С‹С‡РЅС‹Рј VR-СЌРєСЂР°РЅРѕРј Рё Р±РѕР»СЊС€РёРј VR-СЌРєСЂР°РЅРѕРј
    /// РґР»СЏ РІРёРґРµРѕ. Р­С‚Рѕ РІСЃС‘ РµС‰С‘ С‚Р° Р¶Рµ РјРёСЂРѕРІР°СЏ СЃС‚РµСЂРµРѕ-РїР°РЅРµР»СЊ: РјРµРЅСЏРµС‚СЃСЏ С‚РѕР»СЊРєРѕ
    /// РµС‘ СЂР°Р·РјРµСЂ, РїРѕСЌС‚РѕРјСѓ YouTube РѕСЃС‚Р°С‘С‚СЃСЏ РІРЅСѓС‚СЂРё VR-РєРѕРјРїРѕР·РёС‚РѕСЂР°.
    private func setCinemaMode(_ active: Bool) {
        guard inVR else { return }

        if !active {
            isCinemaMode = false
            browserWorldWidth = Self.defaultPanelWidth
            browserWorldHeight = Self.defaultPanelHeight
            browserPlaneGeometry.width = CGFloat(browserWorldWidth)
            browserPlaneGeometry.height = CGFloat(browserWorldHeight)
            browserFrameGeometry.width = CGFloat(browserWorldWidth) + 0.018
            browserFrameGeometry.height = CGFloat(browserWorldHeight) + 0.018
            browserHandleNode.position = SCNVector3(0, -Double(browserWorldHeight) * 0.5 - 0.028, 0)
            toolbarNode.isHidden = false
            hideDirectVideoStage()
            startBrowserCapture()
            return
        }

        guard let url = browser.url, isDirectVideoSite(url) else {
            // РЎРѕС…СЂР°РЅСЏРµРј СЃС‚Р°СЂС‹Р№ fallback РґР»СЏ СЃР°Р№С‚РѕРІ, РіРґРµ РїСЂСЏРјРѕР№ WKWebView СЃР»РѕР№
            // РЅРµ РЅСѓР¶РµРЅ. Р”Р»СЏ YouTube/TikTok РЅРёР¶Рµ РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ СЂРµР°Р»СЊРЅС‹Р№ video layer.
            isCinemaMode = true
            browserWorldWidth = Self.cinemaPanelWidth
            browserWorldHeight = browserWorldWidth * Self.defaultPanelAspect
            browserPlaneGeometry.width = CGFloat(browserWorldWidth)
            browserPlaneGeometry.height = CGFloat(browserWorldHeight)
            browserFrameGeometry.width = CGFloat(browserWorldWidth) + 0.018
            browserFrameGeometry.height = CGFloat(browserWorldHeight) + 0.018
            browserHandleNode.position = SCNVector3(0, -Double(browserWorldHeight) * 0.5 - 0.028, 0)
            toolbarNode.isHidden = true
            startBrowserCapture()
            return
        }

        isCinemaMode = true
        browserWorldWidth = Self.cinemaPanelWidth
        browserWorldHeight = browserWorldWidth * Self.defaultPanelAspect
        browserPlaneGeometry.width = CGFloat(browserWorldWidth)
        browserPlaneGeometry.height = CGFloat(browserWorldHeight)
        browserFrameGeometry.width = CGFloat(browserWorldWidth) + 0.018
        browserFrameGeometry.height = CGFloat(browserWorldHeight) + 0.018
        browserHandleNode.position = SCNVector3(0, -Double(browserWorldHeight) * 0.5 - 0.028, 0)
        toolbarNode.isHidden = true

        pauseAndMuteBrowserMedia()
        activateMediaAudioSession()
        presentDirectVideoStage(url: url)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func isDirectVideoSite(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("youtube.com") || host.contains("youtube-nocookie.com") || host.contains("youtu.be") || host.contains("tiktok.com")
    }

    private func buildToolbar() {
        var items: [ToolbarItem] = [
            ToolbarItem(title: "Р”РѕРјРѕР№", action: .home),
            ToolbarItem(title: "РќР°Р·Р°Рґ", action: .back),
            ToolbarItem(title: "YouTube", action: .open(Self.youTubeURL)),
            ToolbarItem(title: "Р¦РµРЅС‚СЂ", action: .center)
        ]

        let gap: Float = 0.014
        let count = Float(items.count)
        let buttonWidth = (browserWorldWidth - gap * (count - 1)) / count
        toolbarCenterY = browserWorldHeight * 0.5 + 0.02 + toolbarButtonHeight * 0.5

        for index in items.indices {
            let minX = -browserWorldWidth * 0.5 + Float(index) * (buttonWidth + gap)
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
            material.diffuse.contents = MainViewController.buttonImage(
                title: items[index].title,
                highlighted: false
            )
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

    /// РўРµРєСЃС‚СѓСЂР° РєРЅРѕРїРєРё. Р РёСЃСѓРµРј Р·Р°СЂР°РЅРµРµ вЂ” РІ VR РЅРµС‚ РјРµСЃС‚Р° РґР»СЏ UIKit-СЃР»РѕС‘РІ.
    private static func buttonImage(title: String, highlighted: Bool) -> UIImage {
        let size = CGSize(width: 320, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 30)
            let background = highlighted
                ? UIColor(red: 0.30, green: 0.68, blue: 0.95, alpha: 1)
                : UIColor(white: 0.14, alpha: 1)
            background.setFill()
            path.fill()

            UIColor(white: highlighted ? 1.0 : 0.42, alpha: 1).setStroke()
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

        // Р›Р°РґРѕРЅСЊ вЂ” РїСЂРёРїР»СЋСЃРЅСѓС‚С‹Р№ СЌР»Р»РёРїСЃРѕРёРґ, РѕСЂРёРµРЅС‚РёСЂСѓРµС‚СЃСЏ РІРґРѕР»СЊ wristв†’middleMCP.
        let palmGeometry = SCNSphere(radius: 1)
        palmGeometry.segmentCount = 20
        palmGeometry.firstMaterial = jointMaterial.copy() as? SCNMaterial
        let palmNode = SCNNode(geometry: palmGeometry)
        palmNode.renderingOrder = 219
        palmNode.isHidden = true
        root.addChildNode(palmNode)
        palm = palmNode

        // Р Р°РґРёСѓСЃС‹ СЃСѓСЃС‚Р°РІРѕРІ РїРѕ РјРµСЃС‚Сѓ вЂ” Сѓ Р·Р°РїСЏСЃС‚СЊСЏ С‚РѕР»С‰Рµ, Рє РєРѕРЅС‡РёРєР°Рј С‚РѕРЅСЊС€Рµ.
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
        // Р›СѓС‡. Р¦РёР»РёРЅРґСЂ РІС‹С‚СЏРіРёРІР°РµС‚СЃСЏ РїРѕ РґР»РёРЅРµ РєР°Р¶РґС‹Р№ РєР°РґСЂ.
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

        // РўРѕС‡РєР° РїРѕРїР°РґР°РЅРёСЏ: РґРёСЃРє РїР»СЋСЃ РєРѕР»СЊС†Рѕ РІРѕРєСЂСѓРі.
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

    /// РџРµСЂРµСЃС‡РёС‚С‹РІР°РµС‚ IPD Рё РјР°С‚СЂРёС†С‹ РїСЂРѕРµРєС†РёРё РїРѕРґ С‚РµРєСѓС‰РёР№ РїСЂРѕС„РёР»СЊ С€Р»РµРјР°.
    private func applyEyeGeometry() {
        let halfIPD = profile.ipdMM * 0.0005   // РјРј в†’ Рј Рё РїРѕРїРѕР»Р°Рј
        leftCameraNode.simdPosition = SIMD3<Float>(-halfIPD, 0, 0)
        rightCameraNode.simdPosition = SIMD3<Float>(halfIPD, 0, 0)

        let near: Float = 0.02
        let far: Float = 100
        let left = VRLensMath.frustum(eye: 0, profile: profile)
        let right = VRLensMath.frustum(eye: 1, profile: profile)
        leftCameraNode.camera?.projectionTransform = VRLensMath.projection(left, near: near, far: far)
        rightCameraNode.camera?.projectionTransform = VRLensMath.projection(right, near: near, far: far)
    }

    private func configureDirectVideoStage() {
        directVideoStage.backgroundColor = .black
        directVideoStage.clipsToBounds = true

        directVideoLeft = makeDirectVideoWebView(role: "left")
        directVideoRight = makeDirectVideoWebView(role: "right")
        directVideoStage.addSubview(directVideoLeft)
        directVideoStage.addSubview(directVideoRight)

        directVideoLensMask.backgroundColor = .clear
        directVideoLensMask.isUserInteractionEnabled = false
        directVideoStage.addSubview(directVideoLensMask)

        directVideoPointer.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        directVideoPointer.layer.cornerRadius = 9
        directVideoPointer.layer.borderWidth = 2
        directVideoPointer.layer.borderColor = UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 1).cgColor
        directVideoPointer.backgroundColor = .white
        directVideoPointer.layer.shadowColor = UIColor.black.cgColor
        directVideoPointer.layer.shadowOpacity = 0.7
        directVideoPointer.layer.shadowRadius = 5
        directVideoPointer.isHidden = true
        directVideoStage.addSubview(directVideoPointer)
    }

    private func makeDirectVideoWebView(role: String) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
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
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
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
        webView.customUserAgent = browser.customUserAgent
        return webView
    }

    private static func directVideoRoleScript(role: String) -> String {
        let muted = role == "right" ? "true" : "false"
        return """
        (function(){
          window.__handarDirectRole = '\(role)';
          window.__handarDirectMuted = \(muted);
          function video(){
            var all=[].slice.call(document.querySelectorAll('video'));
            all.sort(function(a,b){return (b.clientWidth*b.clientHeight)-(a.clientWidth*a.clientHeight);});
            return all[0]||null;
          }
          window.__handarTuneDirectVideo=function(){
            var v=video(); if(!v) return;
            try{v.setAttribute('playsinline','');v.setAttribute('webkit-playsinline','');v.playsInline=true;}catch(e){}
            try{v.muted=window.__handarDirectMuted;v.volume=window.__handarDirectMuted?0:1;}catch(e){}
          };
          window.__handarDirectPlay=function(){
            var v=video(); if(!v) return;
            try{v.muted=false;v.volume=1;}catch(e){}
            try{
              v.style.setProperty('display','block','important');
              v.style.setProperty('visibility','visible','important');
              v.style.setProperty('opacity','1','important');
              v.style.setProperty('background-color','#000','important');
              v.style.setProperty('object-fit','contain','important');
              v.style.setProperty('transform','translateZ(0)','important');
            }catch(e){}
            try{var p=v.play();if(p&&p.catch){p.catch(function(){})}}catch(e){}
          };
          var style=document.createElement('style');
          style.textContent='html,body{background:#000!important;margin:0!important;} video{display:block!important;visibility:visible!important;opacity:1!important;transform:translateZ(0)!important;}';
          (document.head||document.documentElement).appendChild(style);
          setInterval(window.__handarTuneDirectVideo,800);
          setTimeout(window.__handarTuneDirectVideo,50);
          setTimeout(window.__handarDirectPlay,600);
        })();
        """
    }

    private func layoutDirectVideoStage() {
        let bounds = view.bounds
        directVideoStage.frame = bounds
        let padding: CGFloat = 8
        let gap: CGFloat = 10
        let diameter = max(1, min(bounds.height - padding * 2,
                                  (bounds.width - padding * 2 - gap) * 0.5))
        let total = diameter * 2 + gap
        let startX = (bounds.width - total) * 0.5
        let startY = (bounds.height - diameter) * 0.5
        let left = CGRect(x: startX, y: startY, width: diameter, height: diameter)
        let right = CGRect(x: startX + diameter + gap, y: startY, width: diameter, height: diameter)
        directVideoLeft.frame = left
        directVideoRight.frame = right

        // Hardware-decoded HTML5 video inside WKWebView can render black when
        // the WKWebView layer itself is clipped by cornerRadius/masksToBounds.
        // Keep the two video webviews rectangular and draw the circular lens
        // cut-outs in a sibling overlay instead. This preserves the VR lens
        // appearance without masking the video layer itself.
        directVideoLeft.layer.cornerRadius = 0
        directVideoRight.layer.cornerRadius = 0
        directVideoLeft.clipsToBounds = false
        directVideoRight.clipsToBounds = false
        directVideoLensMask.frame = directVideoStage.bounds
        directVideoLensMask.leftCircle = left
        directVideoLensMask.rightCircle = right
        directVideoLensMask.setNeedsDisplay()
    }

    private func directVideoTarget(for point: CGPoint) -> (WKWebView, CGPoint)? {
        guard let left = directVideoLeft, let right = directVideoRight else { return nil }
        let candidates: [(WKWebView, CGRect)] = [
            (left, left.frame),
            (right, right.frame)
        ]
        for (w, frame) in candidates {
            guard frame.contains(point), frame.width > 1, frame.height > 1 else { continue }
            let local = CGPoint(x: (point.x - frame.minX) / frame.width,
                                y: (point.y - frame.minY) / frame.height)
            let dx = local.x - 0.5
            let dy = local.y - 0.5
            if dx * dx + dy * dy <= 0.25 { return (w, local) }
        }
        return nil
    }

    private func presentDirectVideoStage(url: URL) {
        directVideoURL = url
        directVideoActive = true
        directVideoStage.isHidden = false
        layoutDirectVideoStage()
        directVideoStage.bringSubviewToFront(directVideoPointer)
        view.bringSubviewToFront(directVideoStage)

        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        directVideoLeft.load(request)
        directVideoRight.load(request)

        directVideoSyncTimer?.invalidate()
        directVideoSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.syncDirectVideoEyes()
        }
    }

    private func hideDirectVideoStage() {
        directVideoActive = false
        directVideoSyncTimer?.invalidate()
        directVideoSyncTimer = nil
        directVideoPointer.isHidden = true
        directVideoStage.isHidden = true
        directVideoURL = nil
        input.release(webView: directVideoLeft)
        input.release(webView: directVideoRight)
        pauseAndMute(directVideoLeft)
        pauseAndMute(directVideoRight)
        directVideoLeft?.stopLoading()
        directVideoRight?.stopLoading()
    }

    private func activateMediaAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowBluetoothA2DP])
            try session.setActive(true)
            mediaAudioSessionActive = true
        } catch {
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
        webView?.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(v){try{v.muted=true;v.pause();}catch(e){}});", completionHandler: nil)
    }

    private func activateDirectVideoAudio() {
        activateMediaAudioSession()
        directVideoLeft?.evaluateJavaScript("window.__handarDirectPlay ? window.__handarDirectPlay() : null;", completionHandler: nil)
    }

    private func syncDirectVideoEyes() {
        guard directVideoActive else { return }
        let stateJS = """
        (function(){
          var all=[].slice.call(document.querySelectorAll('video'));
          all.sort(function(a,b){return (b.clientWidth*b.clientHeight)-(a.clientWidth*a.clientHeight);});
          var v=all[0];
          if(!v) return 'null';
          return JSON.stringify({t:v.currentTime||0,p:v.paused,s:v.playbackRate||1});
        })();
        """
        directVideoLeft.evaluateJavaScript(stateJS) { [weak self] result, _ in
            guard let self, let raw = result as? String, raw != "null",
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let state = object as? [String: Any],
                  let t = state["t"] as? Double,
                  let paused = state["p"] as? Bool else { return }
            let rate = state["s"] as? Double ?? 1.0
            let rightJS = """
            (function(){
              var all=[].slice.call(document.querySelectorAll('video'));
              all.sort(function(a,b){return (b.clientWidth*b.clientHeight)-(a.clientWidth*a.clientHeight);});
              var v=all[0]; if(!v) return;
              try{if(Math.abs((v.currentTime||0)-\(t))>0.35){v.currentTime=\(t);}}catch(e){}
              try{v.playbackRate=\(rate);}catch(e){}
              try{if(\(paused ? "true" : "false")){v.pause();}else{var p=v.play();if(p&&p.catch){p.catch(function(){})}}}catch(e){}
            })();
            """
            self.directVideoRight.evaluateJavaScript(rightJS, completionHandler: nil)
        }
    }

    private func removeDirectVideoMessageHandlers() {
        // Direct video WKWebViews use real screen touches; no message handlers are
        // registered on them. This method is kept for symmetric lifecycle cleanup.
    }

    private func configureBrowser() {
        browser.navigationDelegate = self
        browser.uiDelegate = self
        // WebInput.js СЃР»РµРґРёС‚ Р·Р° РїР»РµРµСЂРѕРј СЃС‚СЂР°РЅРёС†С‹ Рё С€Р»С‘С‚ СЃСЋРґР° true/false,
        // РєРѕРіРґР° РІРёРґРµРѕ РЅР° YouTube/TikTok СЂР°Р·РІРѕСЂР°С‡РёРІР°РµС‚СЃСЏ РЅР° РІРµСЃСЊ СЌРєСЂР°РЅ вЂ”
        // СЌС‚Рѕ Рё РІРєР»СЋС‡Р°РµС‚ РєРёРЅРѕСЂРµР¶РёРј.
        browser.configuration.userContentController.add(self, name: "handarVideo")
        browser.configuration.userContentController.add(self, name: "handarApp")
        browser.configuration.userContentController.add(self, name: "handarSystem")
        browser.loadHTMLString(Self.vrDesktopHTML, baseURL: URL(string: "https://handar.vision/") )
    }

    private func buildInterface() {
        // Р‘СЂР°СѓР·РµСЂ Р¶РёРІС‘С‚ РїРѕРґ VR-РІС‹РІРѕРґРѕРј: РµРјСѓ РЅСѓР¶РµРЅ РЅР°СЃС‚РѕСЏС‰РёР№ СЂР°Р·РјРµСЂ Рё РѕРєРЅРѕ,
        // РёРЅР°С‡Рµ takeSnapshot РѕС‚РґР°С‘С‚ РїСѓСЃС‚РѕС‚Сѓ.
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
        menu.onProfileChange = { [weak self] updated in
            guard let self else { return }
            self.profile = updated
            self.applyEyeGeometry()
        }
        menu.onDiagnostics = { [weak self] in
            self?.showVRBoxDiagnostics()
        }
        menu.onSecurityGame = { [weak self] in
            self?.startSecurityVR()
        }
        view.addSubview(menu)

        // Р’РЅСѓС‚СЂРё VR СЌРєСЂР°РЅ РЅРµ РґР»СЏ РїР°Р»СЊС†РµРІ, РїРѕСЌС‚РѕРјСѓ Р¶РµСЃС‚РѕРІ СЂРѕРІРЅРѕ РґРІР°.
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

        // Р’РЅСѓС‚СЂРµРЅРЅРёР№ WKWebView СЂРµРЅРґРµСЂРёРј РІ С„РёРєСЃРёСЂРѕРІР°РЅРЅРѕРј 16:9, С‡С‚РѕР±С‹
        // СЃРЅРёРјРѕРє СЃС‚СЂР°РЅРёС†С‹ РЅРµ РїСЂРµРІСЂР°С‰Р°Р»СЃСЏ РІ РєРІР°РґСЂР°С‚. РЎР°Рј VR-РІС‹РІРѕРґ РїСЂРё СЌС‚РѕРј
        // Р·Р°РЅРёРјР°РµС‚ 100% С„РёР·РёС‡РµСЃРєРѕРіРѕ СЌРєСЂР°РЅР°.
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
            self.hands.process(pixelBuffer: pixelBuffer, orientation: orientation)
        }

        tracking.onCamera = { [weak self] frame in
            DispatchQueue.main.async {
                guard let self, self.inVR else { return }
                self.headNode.simdTransform = self.tracking.headTransform(frame)
                self.ensureBrowserAnchor(using: frame.camera.transform)
            }
        }

        tracking.onAnchorUpdate = { [weak self] anchor in
            DispatchQueue.main.async {
                guard let self, self.inVR, !self.isDragging else { return }
                guard self.browserAnchor?.identifier == anchor.identifier else { return }
                self.browserAnchor = anchor
                self.browserWorldTransform = anchor.transform
                self.applyBrowserWorldTransform()
            }
        }

        tracking.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.leaveVRToMenu()
                self?.showAlert(message)
            }
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
            // Р”Р»СЏ Р±СѓРґСѓС‰РµРіРѕ 6DoF-РїСЂРѕС„РёР»СЏ СЃРѕС…СЂР°РЅСЏРµРј СЃР°Рј С„Р°РєС‚ motion; С‚РµРєСѓС‰Р°СЏ
            // РІРёСЂС‚СѓР°Р»СЊРЅР°СЏ СЂСѓРєР° РёСЃРїРѕР»СЊР·СѓРµС‚ СЃС‚РёРє РєР°Рє РЅР°РґС‘Р¶РЅС‹Р№ 2D-РїРѕР·РёС†РёРѕРЅРµСЂ.
            self?.controllerConnected = true
        }

        hands.onUpdate = { [weak self] left, right in
            DispatchQueue.main.async {
                self?.handleHands(left: left, right: right)
            }
        }
    }

    // MARK: Р’С…РѕРґ Рё РІС‹С…РѕРґ

    private func requestCameraAndEnterVR() {
        guard !inVR else { return }
        guard compositor != nil else {
            showAlert("РќРµ СѓРґР°Р»РѕСЃСЊ РёРЅРёС†РёР°Р»РёР·РёСЂРѕРІР°С‚СЊ VR-СЂРµРЅРґРµСЂ.")
            return
        }
        guard ARWorldTrackingConfiguration.isSupported else {
            showAlert("Р­С‚РѕС‚ iPhone РЅРµ РїРѕРґРґРµСЂР¶РёРІР°РµС‚ ARKit World Tracking.")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            enterVR()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if allowed {
                        self.enterVR()
                    } else {
                        self.showAlert("РќСѓР¶РµРЅ РґРѕСЃС‚СѓРї Рє Р·Р°РґРЅРµР№ РєР°РјРµСЂРµ РґР»СЏ VR.")
                    }
                }
            }
        case .denied, .restricted:
            showAlert("Р Р°Р·СЂРµС€Рё РєР°РјРµСЂСѓ РІ РќР°СЃС‚СЂРѕР№РєРё в†’ HandAR Vision в†’ РљР°РјРµСЂР°.")
        @unknown default:
            showAlert("РќРµ СѓРґР°Р»РѕСЃСЊ РїСЂРѕРІРµСЂРёС‚СЊ РґРѕСЃС‚СѓРї Рє РєР°РјРµСЂРµ.")
        }
    }

    private func enterVR() {
        guard !inVR else { return }
        inVR = true
        didCreateInitialAnchor = false
        browserAnchor = nil
        browserWorldTransform = nil
        isDragging = false
        wasClickPinching = false
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

    /// РљР°Р¶РґС‹Р№ Р·Р°С…РѕРґ РІ VR РЅР°С‡РёРЅР°РµС‚СЃСЏ СЃ РѕР±С‹С‡РЅРѕРіРѕ СЂР°Р·РјРµСЂР° РїР°РЅРµР»Рё, Р±РµР· Р°РЅРёРјР°С†РёРё вЂ”
    /// РїР°РЅРµР»СЊ РІ СЌС‚РѕС‚ РјРѕРјРµРЅС‚ РµС‰С‘ СЃРєСЂС‹С‚Р°, РґРѕРёРіСЂС‹РІР°С‚СЊ РїРµСЂРµС…РѕРґ РЅРµ РґР»СЏ РєРѕРіРѕ.
    private func resetPanelToDefaultSizeInstantly() {
        isCinemaMode = false
        browserWorldWidth = Self.defaultPanelWidth
        browserWorldHeight = Self.defaultPanelHeight

        updatePanelSize(width: browserWorldWidth)
        toolbarNode.opacity = 1
        toolbarNode.isHidden = false
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
    private func startSecurityVR() {
        guard !inVR else { return }
        inVR = true
        securityGameActive = true

        applyEyeGeometry()
        requestLandscapeMode()
        setVRVisible(true)
        hidePointer()
        hidePointerDot()
        releasePointer()

        tracking.setInterfaceOrientation(currentInterfaceOrientation())
        tracking.start()

        let forward = simd_normalize(SIMD3<Float>(
            -headNode.simdWorldTransform.columns.2.x,
            0,
            -headNode.simdWorldTransform.columns.2.z
        ))
        securityGame.onExitRequested = { [weak self] in
            self?.exitSecurityVR()
        }
        securityGame.start(
            in: worldScene,
            cameraOrigin: headNode.simdWorldPosition,
            cameraForward: forward
        )

        UIApplication.shared.isIdleTimerDisabled = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func exitSecurityVR() {
        securityGame.stop()
        securityGameActive = false
        leaveVRToMenu()
    }

    private func leaveVRToMenu() {
        tracking.pause()
        stopBrowserCapture()
        hideDirectVideoStage()
        releasePointer()

        if securityGameActive {
            securityGame.stop()
            securityGameActive = false
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
        guard inVR else { return }
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

    // MARK: РџР°РЅРµР»СЊ Р±СЂР°СѓР·РµСЂР° РІ РјРёСЂРµ

    private func ensureBrowserAnchor(using cameraTransform: simd_float4x4) {
        guard inVR, !didCreateInitialAnchor else { return }
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

    /// РџР°РЅРµР»СЊ РІСЃРµРіРґР° СЃС‚РѕРёС‚ РІРµСЂС‚РёРєР°Р»СЊРЅРѕ: РЅР°РєР»РѕРЅ РіРѕР»РѕРІС‹ РЅРµ РґРѕР»Р¶РµРЅ РµС‘ Р·Р°РІР°Р»РёРІР°С‚СЊ.
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

    /// РџРµСЂРµРІРµС€РёРІР°РµС‚ СЏРєРѕСЂСЊ РЅР° С‚РµРєСѓС‰РµРµ РїРѕР»РѕР¶РµРЅРёРµ РїР°РЅРµР»Рё. ARAnchor РЅРµРёР·РјРµРЅСЏРµРј,
    /// РїРѕСЌС‚РѕРјСѓ СЃС‚Р°СЂС‹Р№ СЃРЅРёРјР°РµС‚СЃСЏ, РЅРѕРІС‹Р№ СЃС‚Р°РІРёС‚СЃСЏ.
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
        browserPlaneNode.simdWorldTransform = transform
        browserPlaneNode.isHidden = !inVR
    }

    private func resetBrowserAnchor() {
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
        browserTimer?.invalidate()
        // Р§С‚РµРЅРёРµ СЃС‚СЂР°РЅРёС†С‹ СЃРЅРѕСЃРЅРѕ СЃРјРѕС‚СЂРёС‚СЃСЏ РЅР° 12 fps. Р’РёРґРµРѕ РЅР° 12 fps
        // РґС‘СЂРіР°РµС‚СЃСЏ Р·Р°РјРµС‚РЅРѕ, РїРѕСЌС‚РѕРјСѓ РІ РєРёРЅРѕСЂРµР¶РёРјРµ РїРѕРґРЅРёРјР°РµРј С‡Р°СЃС‚РѕС‚Сѓ.
        let interval = isCinemaMode ? (1.0 / 24.0) : (1.0 / 12.0)
        browserTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateBrowserSnapshot()
        }
    }

    private func stopBrowserCapture() {
        browserTimer?.invalidate()
        browserTimer = nil
    }

    private func updateBrowserSnapshot() {
        guard inVR, !directVideoActive, !snapshotInProgress else { return }
        guard browser.bounds.width > 1, browser.bounds.height > 1 else { return }
        snapshotInProgress = true

        let configuration = WKSnapshotConfiguration()
        // РљРёРЅРѕРїР°РЅРµР»СЊ РїРѕС‡С‚Рё РІРґРІРѕРµ С€РёСЂРµ РѕР±С‹С‡РЅРѕР№ вЂ” С‚РѕС‚ Р¶Рµ СЃРЅРёРјРѕРє РЅР° РЅРµР№
        // СЂР°Р·РјС‹Р»РёР»СЃСЏ Р±С‹, РїРѕСЌС‚РѕРјСѓ Р±РµСЂС‘Рј РµРіРѕ РєСЂСѓРїРЅРµРµ.
        configuration.snapshotWidth = NSNumber(value: isCinemaMode ? 1536 : 1280)
        browser.takeSnapshot(with: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshotInProgress = false
                guard let image else { return }
                self.browserMaterial.diffuse.contents = image
                self.browserMaterial.emission.contents = image
            }
        }
    }

    // MARK: Р СѓРєРё Рё СѓРєР°Р·Р°С‚РµР»СЊ

    private func handleControllerStick(x: CGFloat, y: CGFloat) {
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
        guard inVR, controllerConnected else { return }
        guard CACurrentMediaTime() - lastHandSeenTime > 0.45 else { return }
        switch button {
        case .a:
            controllerButtonDown = pressed
            updateControllerHand()
        case .b:
            if pressed {
                if directVideoActive {
                    hideDirectVideoStage()
                    setCinemaMode(false)
                } else if browser.canGoBack {
                    browser.goBack()
                }
            }
        case .x:
            if pressed { openVRDesktop() }
        case .y:
            if pressed { resetBrowserAnchor(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        case .menu:
            if pressed { leaveVRToMenu() }
        }
    }

    private func updateControllerHand() {
        if directVideoActive {
            controllerHandRoot.isHidden = true
            let screen = CGPoint(x: controllerPointer.x * view.bounds.width, y: controllerPointer.y * view.bounds.height)
            if let (webView, local) = directVideoTarget(for: screen) {
                directVideoPointer.isHidden = false
                directVideoPointer.center = screen
                directVideoPointer.backgroundColor = controllerButtonDown ? UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 0.9) : .white
                input.update(normalizedPoint: local, pinch: controllerButtonDown, webView: webView)
                if controllerButtonDown { activateDirectVideoAudio() }
            } else {
                directVideoPointer.isHidden = true
                input.release(webView: directVideoLeft)
                input.release(webView: directVideoRight)
            }
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
        input.update(normalizedPoint: CGPoint(x: x, y: y), pinch: controllerButtonDown, webView: browser)
    }

    private func handleDirectVideoHands(left: HandSample?, right: HandSample?) {
        guard let sample = right ?? left, let frame = tracking.latestFrameCopy else {
            directVideoPointer.isHidden = true
            input.release(webView: directVideoLeft)
            input.release(webView: directVideoRight)
            return
        }
        let oriented = sample.indexTip.applying(
            frame.displayTransform(for: currentInterfaceOrientation(), viewportSize: view.bounds.size)
        )
        let screenPoint = CGPoint(x: oriented.x * view.bounds.width, y: oriented.y * view.bounds.height)
        guard let (webView, local) = directVideoTarget(for: screenPoint) else {
            directVideoPointer.isHidden = true
            if !sample.clickPinch {
                input.release(webView: directVideoLeft)
                input.release(webView: directVideoRight)
            }
            return
        }
        directVideoPointer.isHidden = false
        directVideoPointer.center = screenPoint
        directVideoPointer.backgroundColor = sample.clickPinch ? UIColor(red: 0.35, green: 0.85, blue: 1, alpha: 0.9) : .white
        input.update(normalizedPoint: local, pinch: sample.clickPinch, webView: webView)
        if sample.clickPinch { activateDirectVideoAudio() }
        if let left = directVideoLeft, let right = directVideoRight {
            let other: WKWebView = webView === left ? right : left
            if !sample.clickPinch { input.release(webView: other) }
        }
    }

    private func handleHands(left: HandSample?, right: HandSample?) {
        guard inVR else { return }
        if directVideoActive {
            handleDirectVideoHands(left: left, right: right)
            return
        }
        queueHandForegroundMask(left: left, right: right)

        if securityGameActive {
            if let sample = right ?? left,
               let ray = tracking.worldRay(visionPoint: sample.indexTip) {
                securityGame.update(ray: ray, pinch: sample.clickPinch)
            } else {
                securityGame.update(ray: nil, pinch: false)
            }
            lastHandSeenTime = CACurrentMediaTime()
            controllerHandRoot.isHidden = true
            return
        }

        if left != nil || right != nil {
            lastHandSeenTime = CACurrentMediaTime()
            controllerHandRoot.isHidden = true
        }

        // Р”РІРµ СЂСѓРєРё: СЃСЂРµРґРЅРёР№+Р±РѕР»СЊС€РѕР№ РїР°Р»РµС† = СЂРµР¶РёРј РёР·РјРµРЅРµРЅРёСЏ СЂР°Р·РјРµСЂР°.
        // Р Р°СЃС…РѕРґСЏС‚СЃСЏ СѓРєР°Р·Р°С‚РµР»СЊРЅС‹Рµ вЂ” РѕРєРЅРѕ СѓРІРµР»РёС‡РёРІР°РµС‚СЃСЏ, СЃС…РѕРґСЏС‚СЃСЏ вЂ” СѓРјРµРЅСЊС€Р°РµС‚СЃСЏ.
        if let left, let right, left.clickPinch && right.clickPinch {
            updateResize(left: left, right: right)
            endDrag()
            releasePointer()
            hidePointer()
            wasClickPinching = true
            return
        }

        if isResizing {
            endResize()
        }

        guard
            let sample = right ?? left,
            let ray = tracking.worldRay(visionPoint: sample.indexTip)
        else {
            endDrag()
            releasePointer()
            hidePointer()
            wasClickPinching = false
            if controllerConnected && CACurrentMediaTime() - lastHandSeenTime > 0.45 {
                updateControllerHand()
            } else {
                controllerHandRoot.isHidden = true
            }
            return
        }

        // Р—Р°С…РІР°С‚: СѓРєР°Р·Р°С‚РµР»СЊРЅС‹Р№ + Р±РѕР»СЊС€РѕР№, СЂСѓРєР° РІ РЅРёР¶РЅРµР№ С‚СЂРµС‚Рё РєР°РґСЂР°.
        let inDragZone = sample.indexTip.y < dragZoneHeight
        if sample.grabPinch && (isDragging || inDragZone) {
            updateDrag(with: ray)
            releasePointer()
            highlightToolbar(nil)
            pointerNode.isHidden = true
            wasClickPinching = false
            return
        }
        endDrag()

        guard let transform = browserWorldTransform else {
            showRay(from: ray, hit: nil)
            hidePointerDot()
            releasePointer()
            wasClickPinching = sample.clickPinch
            return
        }

        guard let hit = planeHit(ray: ray, transform: transform) else {
            showRay(from: ray, hit: nil)
            hidePointerDot()
            releasePointer()
            highlightToolbar(nil)
            wasClickPinching = sample.clickPinch
            return
        }

        showRay(from: ray, hit: hit.point)
        showPointerDot(at: hit.point, transform: transform, active: sample.clickPinch)

        // РџР»Р°РЅРєР° СЃСЃС‹Р»РѕРє РЅР°Рґ Р±СЂР°СѓР·РµСЂРѕРј. Р’Рѕ РІСЂРµРјСЏ РІРёРґРµРѕ РѕРЅР° СЃРєСЂС‹С‚Р° вЂ”
        // РїСЂРѕРїСѓСЃРєР°РµРј Рё Р·РѕРЅСѓ РїРѕРїР°РґР°РЅРёСЏ, РёРЅР°С‡Рµ РїР°Р»РµС† В«С‰С‘Р»РєР°Р»В» Р±С‹ РїРѕ РЅРµРІРёРґРёРјРєРµ.
        if !isCinemaMode, abs(hit.localY - toolbarCenterY) <= toolbarButtonHeight * 0.5 {
            let index = linkItems.firstIndex { hit.localX >= $0.minX && hit.localX <= $0.maxX }
            highlightToolbar(index)
            releasePointer()
            if let index, sample.clickPinch, !wasClickPinching {
                perform(item: linkItems[index])
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
            wasClickPinching = sample.clickPinch
            return
        }
        highlightToolbar(nil)

        let normalizedX = hit.localX / browserWorldWidth + 0.5
        let normalizedY = 0.5 - hit.localY / browserWorldHeight
        guard normalizedX >= 0, normalizedX <= 1, normalizedY >= 0, normalizedY <= 1 else {
            releasePointer()
            wasClickPinching = sample.clickPinch
            return
        }

        input.update(
            normalizedPoint: CGPoint(x: CGFloat(normalizedX), y: CGFloat(normalizedY)),
            pinch: sample.clickPinch,
            webView: browser
        )
        wasClickPinching = sample.clickPinch
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
            let buttonWidth = max(0.06, (browserWorldWidth - gap * (count - 1)) / count)
            toolbarCenterY = browserWorldHeight * 0.5 + 0.02 + toolbarButtonHeight * 0.5
            for index in toolbarButtonNodes.indices {
                let minX = -browserWorldWidth * 0.5 + Float(index) * (buttonWidth + gap)
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

    private func perform(item: ToolbarItem) {
        switch item.action {
        case .open(let url):
            browser.load(URLRequest(url: url))
        case .back:
            if browser.canGoBack {
                browser.goBack()
            }
        case .home:
            openVRDesktop()
        case .center:
            resetBrowserAnchor()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// РџРµСЂРµСЃРµС‡РµРЅРёРµ Р»СѓС‡Р° СЃ РїР»РѕСЃРєРѕСЃС‚СЊСЋ РїР°РЅРµР»Рё. РЎС‡РёС‚Р°РµРј РЅР°РїСЂСЏРјСѓСЋ: СЌС‚Рѕ РґРµС€РµРІР»Рµ
    /// Рё С‡РµСЃС‚РЅРµРµ, С‡РµРј РіРѕРЅСЏС‚СЊ С‚РѕС‡РєСѓ С‡РµСЂРµР· РІСЊСЋРїРѕСЂС‚С‹.
    /// РЎРєРµР»РµС‚ РєР»Р°РґС‘Рј РїСЂСЏРјРѕ РЅР° РјРёСЂРѕРІСѓСЋ РїР»РѕСЃРєРѕСЃС‚СЊ Р±СЂР°СѓР·РµСЂР° Рё СЃРґРІРёРіР°РµРј РЅР° 18 РјРј
    /// Рє РєР°РјРµСЂРµ. РџРѕСЌС‚РѕРјСѓ РїСЂРё РґРІРёР¶РµРЅРёРё Р±СЂР°СѓР·РµСЂР° СЃРєРµР»РµС‚ РѕСЃС‚Р°С‘С‚СЃСЏ СЃРѕРІРјРµС‰С‘РЅРЅС‹Рј
    /// СЃ СЂСѓРєРѕР№, РЅРѕ РЅРµ РїСЂРѕРІР°Р»РёРІР°РµС‚СЃСЏ РїРѕРґ С‚РµРєСЃС‚СѓСЂСѓ СЃС‚СЂР°РЅРёС†С‹.
    private static let handMaskBonePairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip)
    ]

    /// РЎРѕР·РґР°С‘С‚ РјР°СЃРєСѓ РєРёСЃС‚Рё РІ РєРѕРѕСЂРґРёРЅР°С‚Р°С… СЃС‹СЂРѕРіРѕ РєР°РґСЂР° РєР°РјРµСЂС‹. Р’ РЅРµР№ РЅРµС‚
    /// РіСЂР°С„РёРєРё СЃРєРµР»РµС‚Р° вЂ” РѕРЅР° С‚РѕР»СЊРєРѕ РѕРїСЂРµРґРµР»СЏРµС‚, РєР°РєРёРµ РЅР°СЃС‚РѕСЏС‰РёРµ РїРёРєСЃРµР»Рё РєР°РјРµСЂС‹
    /// РЅСѓР¶РЅРѕ РїРѕРєР°Р·Р°С‚СЊ РїРѕРІРµСЂС… Р±СЂР°СѓР·РµСЂР°.
    private func queueHandForegroundMask(left: HandSample?, right: HandSample?) {
        var bytes = [UInt8](repeating: 0, count: handMaskWidth * handMaskHeight)
        let activeSamples = [left, right].compactMap { $0 }
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
            handMaskLock.unlock()
            return
        }

        // Vision/РєР°РјРµСЂР° РёСЃРїРѕР»СЊР·СѓСЋС‚ РІРµСЂС…РЅРёР№ Р»РµРІС‹Р№ СѓРіРѕР» РєР°Рє РЅР°С‡Р°Р»Рѕ UV РІ РЅР°С€РµР№ СЃС…РµРјРµ.
        context.translateBy(x: 0, y: CGFloat(handMaskHeight))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(UIColor.white.cgColor)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for sample in activeSamples {
            drawHandMask(sample, in: context)
        }

        handMaskLock.lock()
        pendingHandMaskBytes = bytes
        pendingHandMaskActive = true
        handMaskLock.unlock()
    }

    private func drawHandMask(_ sample: HandSample, in context: CGContext) {
        let landscapeLeft = currentInterfaceOrientation() == .landscapeLeft
        let width = CGFloat(handMaskWidth - 1)
        let height = CGFloat(handMaskHeight - 1)

        func toRawCameraPoint(_ visionPoint: CGPoint) -> CGPoint {
            var u = visionPoint.x
            var v = visionPoint.y
            if landscapeLeft {
                u = 1 - u
            } else {
                v = 1 - v
            }
            return CGPoint(
                x: min(max(u, 0), 1) * width,
                y: min(max(v, 0), 1) * height
            )
        }

        let palmNames: [VNHumanHandPoseObservation.JointName] = [
            .wrist, .littleMCP, .ringMCP, .middleMCP, .indexMCP
        ]
        let palmPoints = palmNames.compactMap { sample.joints[$0].map(toRawCameraPoint) }
        if palmPoints.count >= 3 {
            let path = CGMutablePath()
            path.move(to: palmPoints[0])
            for point in palmPoints.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }

        let fingerWidth = max(CGFloat(8), min(CGFloat(28), CGFloat(handMaskHeight) * 0.055))
        let palmWidth = fingerWidth * 1.35
        for (a, b) in Self.handMaskBonePairs {
            guard let pa = sample.joints[a].map(toRawCameraPoint),
                  let pb = sample.joints[b].map(toRawCameraPoint) else { continue }
            context.setLineWidth((a == .wrist || b == .wrist) ? palmWidth : fingerWidth)
            context.move(to: pa)
            context.addLine(to: pb)
            context.strokePath()
        }

        let jointRadius = fingerWidth * 0.58
        for point in sample.joints.values.map(toRawCameraPoint) {
            context.fillEllipse(in: CGRect(
                x: point.x - jointRadius,
                y: point.y - jointRadius,
                width: jointRadius * 2,
                height: jointRadius * 2
            ))
        }
    }

    private func syncHandMaskTexture() -> Bool {
        guard let texture = handMaskTexture else { return false }
        handMaskLock.lock()
        let active = pendingHandMaskActive
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

        // Р›Р°РґРѕРЅСЊ: С†РµРЅС‚СЂ вЂ” СЃРµСЂРµРґРёРЅР° РјРµР¶РґСѓ Р·Р°РїСЏСЃС‚СЊС‘Рј Рё СЃСЂРµРґРЅРёРј MCP,
        // РѕСЃСЊ Y вЂ” РѕС‚ Р·Р°РїСЏСЃС‚СЊСЏ Рє СЃСЂРµРґРЅРµРјСѓ MCP, С‚РѕР»С‰РёРЅР° РјР°Р»Р° (РїР»РѕСЃРєР°СЏ СЂСѓРєР°).
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
            // Р—Р°РїРѕРјРёРЅР°РµРј СЃРјРµС‰РµРЅРёРµ, РёРЅР°С‡Рµ РїР°РЅРµР»СЊ РїСЂС‹РіРЅРµС‚ Рє РїР°Р»СЊС†Сѓ РІ РјРѕРјРµРЅС‚ Р·Р°С…РІР°С‚Р°.
            dragOffset = center - ray.point(at: dragDistance)
            input.release(webView: browser)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }

        var moved = transform
        moved.columns.3 = SIMD4<Float>(ray.point(at: dragDistance) + dragOffset, 1)
        browserWorldTransform = moved
        applyBrowserWorldTransform()

        // Р›СѓС‡ С‚СЏРЅРµС‚СЃСЏ Рє РїР°РЅРµР»Рё, РїРѕРєР° РµС‘ С‚Р°С‰Р°С‚.
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

        // Р”РёСЃРє Рё РєРѕР»СЊС†Рѕ СЃС‚СЂРѕСЏС‚СЃСЏ РІРґРѕР»СЊ СЃРІРѕРµР№ Р»РѕРєР°Р»СЊРЅРѕР№ Y, РїРѕСЌС‚РѕРјСѓ Y РєР»Р°РґС‘Рј
        // РЅР° РЅРѕСЂРјР°Р»СЊ РїР°РЅРµР»Рё вЂ” РёРЅР°С‡Рµ С‚РѕС‡РєР° РІСЃС‚Р°РЅРµС‚ СЂРµР±СЂРѕРј.
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
        guard highlightedToolbarIndex != index else { return }
        highlightedToolbarIndex = index
        for (position, node) in toolbarButtonNodes.enumerated() {
            let image = MainViewController.buttonImage(
                title: linkItems[position].title,
                highlighted: position == index
            )
            node.geometry?.firstMaterial?.diffuse.contents = image
            node.geometry?.firstMaterial?.emission.contents = image
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

    // MARK: Р РµРЅРґРµСЂ

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

        ensureEyeTextures(for: drawableSize)
        guard let eyeTexture, let eyeDepthTexture else { return }

        let time = CACurrentMediaTime()
        let eyeWidth = eyeTexture.width / 2
        let eyeHeight = eyeTexture.height

        // РџСЂРѕС…РѕРґ 1 вЂ” Р»РµРІС‹Р№ РіР»Р°Р·. Р¤РѕРЅ РїСЂРѕР·СЂР°С‡РЅС‹Р№: РІРёРґРµРѕ РїРѕРґР»РѕР¶РёС‚ РєРѕРјРїРѕР·РёС‚РѕСЂ.
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

        // РџСЂРѕС…РѕРґ 2 вЂ” РїСЂР°РІС‹Р№ РіР»Р°Р· РІ С‚Сѓ Р¶Рµ С‚РµРєСЃС‚СѓСЂСѓ.
        let rightPass = MTLRenderPassDescriptor()
        rightPass.colorAttachments[0].texture = eyeTexture
        rightPass.colorAttachments[0].loadAction = .load
        rightPass.colorAttachments[0].storeAction = .store
        rightPass.depthAttachment.texture = eyeDepthTexture
        rightPass.depthAttachment.loadAction = .clear
        rightPass.depthAttachment.storeAction = .dontCare
        rightPass.depthAttachment.clearDepth = 1.0

        rightRenderer.pointOfView = rightCameraNode
        rightRenderer.render(
            atTime: time,
            viewport: CGRect(x: CGFloat(eyeWidth), y: 0, width: CGFloat(eyeWidth), height: CGFloat(eyeHeight)),
            commandBuffer: commandBuffer,
            passDescriptor: rightPass
        )

        // РџСЂРѕС…РѕРґ 3 вЂ” РѕРїС‚РёРєР° Р»РёРЅР· РїР»СЋСЃ СЃРєРІРѕР·РЅРѕРµ РІРёРґРµРѕ.
        let frame = tracking.latestFrameCopy
        let cameraTextures = makeCameraTextures(from: frame)
        var uniforms = makeUniforms(
            drawableSize: drawableSize,
            frame: frame,
            hasCamera: cameraTextures != nil
        )
        uniforms.handMaskEnabled = syncHandMaskTexture() ? 1 : 0

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

        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.retainedCameraTextures.removeAll()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms(
        drawableSize: CGSize,
        frame: ARFrame?,
        hasCamera: Bool
    ) -> VRUniforms {
        var uniforms = VRUniforms()
        uniforms.lensCenterL = VRLensMath.lensCenterUV(eye: 0, profile: profile)
        uniforms.lensCenterR = VRLensMath.lensCenterUV(eye: 1, profile: profile)
        uniforms.aspect = Float((drawableSize.width * 0.5) / max(drawableSize.height, 1))
        uniforms.k1 = profile.k1
        uniforms.k2 = profile.k2
        uniforms.chroma = profile.chroma
        // РљСЂСѓРіР»Р°СЏ Р»РёРЅР·Р° РјР°РєСЃРёРјР°Р»СЊРЅРѕ Р·Р°РїРѕР»РЅСЏРµС‚ СЃРІРѕСЋ РїРѕР»РѕРІРёРЅСѓ РґРёСЃРїР»РµСЏ.
        // Р Р°РґРёСѓСЃ РѕРіСЂР°РЅРёС‡РµРЅ Рё РїРѕ РІС‹СЃРѕС‚Рµ, Рё РїРѕ С€РёСЂРёРЅРµ, РїРѕСЌС‚РѕРјСѓ РѕРєСЂСѓР¶РЅРѕСЃС‚СЊ
        // РЅРµ РїСЂРµРІСЂР°С‰Р°РµС‚СЃСЏ РІ РѕРІР°Р» Рё РѕРґРёРЅР°РєРѕРІР° РґР»СЏ РѕР±РѕРёС… РіР»Р°Р·.
        let maxLensRadius = min(0.5, 0.5 / max(uniforms.aspect, 0.001))
        uniforms.rClip = 0.497
        uniforms.passthrough = (profile.passthrough && hasCamera) ? 1 : 0

        guard let frame, profile.passthrough, hasCamera else { return uniforms }

        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        guard fx > 0, fy > 0 else {
            uniforms.passthrough = 0
            return uniforms
        }

        // РџРѕР»РѕРІРёРЅР° РїРѕР»СЏ Р·СЂРµРЅРёСЏ СЂРµР°Р»СЊРЅРѕР№ РєР°РјРµСЂС‹ РІ С‚Р°РЅРіРµРЅСЃР°С….
        let camTanX = Float(resolution.width) * 0.5 / fx
        let camTanY = Float(resolution.height) * 0.5 / fy
        let flip = currentInterfaceOrientation() == .landscapeLeft

        let left = VRLensMath.frustum(eye: 0, profile: profile)
        let right = VRLensMath.frustum(eye: 1, profile: profile)
        let mappedLeft = cameraMapping(for: left, camTanX: camTanX, camTanY: camTanY, flipped: flip)
        let mappedRight = cameraMapping(for: right, camTanX: camTanX, camTanY: camTanY, flipped: flip)

        uniforms.camScaleL = mappedLeft.scale
        uniforms.camOffsetL = mappedLeft.offset
        uniforms.camScaleR = mappedRight.scale
        uniforms.camOffsetR = mappedRight.offset
        return uniforms
    }

    /// Р›РёРЅРµР№РЅРѕРµ РѕС‚РѕР±СЂР°Р¶РµРЅРёРµ РєРѕРѕСЂРґРёРЅР°С‚ РіР»Р°Р·Р° РІ РєРѕРѕСЂРґРёРЅР°С‚С‹ РєР°РґСЂР° РєР°РјРµСЂС‹ С‚Р°Рє,
    /// С‡С‚РѕР±С‹ СѓРіР»РѕРІС‹Рµ СЂР°Р·РјРµСЂС‹ СЃРѕРІРїР°Р»Рё: РїРёРєСЃРµР»СЊ РїРѕРґ СѓРіР»РѕРј X РІ РіР»Р°Р·Сѓ Р±РµСЂС‘С‚СЃСЏ
    /// РёР· РїРёРєСЃРµР»СЏ РїРѕРґ С‚РµРј Р¶Рµ СѓРіР»РѕРј X РІ РєР°РјРµСЂРµ.
    private func cameraMapping(
        for frustum: EyeFrustum,
        camTanX: Float,
        camTanY: Float,
        flipped: Bool
    ) -> (scale: SIMD2<Float>, offset: SIMD2<Float>) {
        var scale = SIMD2<Float>(
            (frustum.right - frustum.left) / (2 * camTanX),
            (frustum.top - frustum.bottom) / (2 * camTanY)
        )
        var offset = SIMD2<Float>(
            0.5 + frustum.left / (2 * camTanX),
            0.5 - frustum.top / (2 * camTanY)
        )

        if flipped {
            // Р’ landscapeLeft РєР°РґСЂ РєР°РјРµСЂС‹ РїРѕРІС‘СЂРЅСѓС‚ РЅР° 180В°.
            scale = -scale
            offset = SIMD2<Float>(1, 1) - offset
        }
        return (scale, offset)
    }

    private func makeCameraTextures(from frame: ARFrame?) -> (MTLTexture, MTLTexture)? {
        guard
            profile.passthrough,
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

        // CVMetalTexture РґРѕР»Р¶РµРЅ РґРѕР¶РёС‚СЊ РґРѕ РєРѕРЅС†Р° РєР°РґСЂР°.
        retainedCameraTextures.append(luma.0)
        retainedCameraTextures.append(chroma.0)
        return (luma.1, chroma.1)
    }

    private func ensureEyeTextures(for drawableSize: CGSize) {
        let factor = CGFloat(max(profile.supersample, 1))
        let target = CGSize(
            width: (drawableSize.width * factor).rounded(),
            height: (drawableSize.height * factor).rounded()
        )
        if eyeTexture != nil, eyeTextureSize == target { return }

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
        case "handarVideo":
            guard
                let body = message.body as? [String: Any],
                let active = body["active"] as? Bool
            else { return }
            // РљРѕРіРґР° direct video СѓР¶Рµ Р°РєС‚РёРІРёСЂРѕРІР°РЅ, РѕСЃРЅРѕРІРЅРѕР№ WKWebView СЃРїРµС†РёР°Р»СЊРЅРѕ
            // СЃС‚Р°РІРёС‚СЃСЏ РЅР° РїР°СѓР·Сѓ. Р•РіРѕ pause-СЃРѕР±С‹С‚РёРµ РЅРµР»СЊР·СЏ С‚СЂР°РєС‚РѕРІР°С‚СЊ РєР°Рє РІС‹С…РѕРґ
            // РёР· РєРёРЅРѕСЂРµР¶РёРјР°, РёРЅР°С‡Рµ РїСЂСЏРјРѕР№ РІРёРґРµРѕСЃР»РѕР№ РјРіРЅРѕРІРµРЅРЅРѕ Р·Р°РєСЂРѕРµС‚СЃСЏ.
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
<!doctype html>
<html lang="ru">
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta charset="utf-8">
<title>HandAR VR Desktop</title>
<style>
:root{--glass:rgba(20,24,34,.54);--glass2:rgba(255,255,255,.12);--text:#fff;--muted:rgba(255,255,255,.7)}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;width:100%;height:100%;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Helvetica Neue",Arial,sans-serif;color:var(--text);background:linear-gradient(145deg,#0e1732 0%,#43276d 50%,#0a132b 100%);}
body:before{content:"";position:fixed;inset:-20%;background:radial-gradient(circle at 28% 30%,rgba(95,170,255,.32),transparent 34%),radial-gradient(circle at 72% 64%,rgba(226,92,255,.28),transparent 32%);filter:blur(28px);}
.wall{position:relative;height:100%;padding:18px 34px 20px;display:flex;flex-direction:column;gap:14px;}
.status{height:30px;display:flex;align-items:center;justify-content:space-between;font-size:16px;font-weight:650;text-shadow:0 2px 10px rgba(0,0,0,.35)}
.status .right{display:flex;gap:10px;align-items:center;font-size:13px;font-weight:550}.status .right span{white-space:nowrap}.pill{padding:6px 10px;border-radius:999px;background:rgba(0,0,0,.22);backdrop-filter:blur(18px)}
.search{height:50px;border-radius:22px;background:rgba(255,255,255,.16);border:1px solid rgba(255,255,255,.25);backdrop-filter:blur(22px);display:flex;align-items:center;gap:12px;padding:0 17px;font-size:17px;color:#fff;box-shadow:0 8px 24px rgba(0,0,0,.14)}
.searchIcon{font-size:19px;opacity:.9}.searchText{opacity:.78}.searchHint{margin-left:auto;font-size:12px;opacity:.52;padding:5px 8px;border-radius:9px;background:rgba(0,0,0,.16)}
.grid{flex:1;display:grid;grid-template-columns:repeat(6,1fr);grid-auto-rows:minmax(88px,1fr);gap:12px 16px;align-items:start;padding:2px 2px 0}
.app{min-width:0;text-align:center;cursor:pointer;user-select:none}.app:active{transform:scale(.93)}
.icon{width:64px;height:64px;margin:0 auto 6px;border-radius:20px;display:flex;align-items:center;justify-content:center;box-shadow:inset 0 1px 1px rgba(255,255,255,.24),0 9px 18px rgba(0,0,0,.20);border:1px solid rgba(255,255,255,.16);overflow:hidden}.icon svg{width:34px;height:34px;fill:none;stroke:#fff;stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round}.icon .solid{fill:#fff;stroke:none}
.app span{display:block;font-size:13px;line-height:16px;font-weight:560;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-shadow:0 1px 6px rgba(0,0,0,.35)}
.blue{background:linear-gradient(135deg,#54a9ff,#1866e8)}.red{background:linear-gradient(135deg,#ff4d55,#cf111c)}.pink{background:linear-gradient(135deg,#ff5bb8,#7d26ff)}.teal{background:linear-gradient(135deg,#42d9ca,#007d87)}.indigo{background:linear-gradient(135deg,#7e82ff,#4647b9)}.green{background:linear-gradient(135deg,#55df76,#159447)}.cyan{background:linear-gradient(135deg,#55d8ff,#1a74db)}.orange{background:linear-gradient(135deg,#ffb657,#e46710)}.gray{background:linear-gradient(135deg,#737b88,#343943)}.dark{background:rgba(13,18,28,.82)}.purple{background:linear-gradient(135deg,#a855f7,#5b21b6)}
.dock{height:82px;border-radius:28px;background:rgba(235,240,255,.18);border:1px solid rgba(255,255,255,.22);backdrop-filter:blur(28px);display:flex;align-items:center;justify-content:space-around;padding:9px 22px;box-shadow:0 12px 30px rgba(0,0,0,.2)}
.dock .icon{width:54px;height:54px;border-radius:17px;margin:0}.dock .app span{display:none}.dock .app{width:56px}
.note{text-align:center;font-size:11px;color:rgba(255,255,255,.48);margin-top:-4px}.launch{animation:launch .22s ease-out}.launch .icon{box-shadow:0 0 0 5px rgba(255,255,255,.28),0 0 30px rgba(255,255,255,.25)}
@keyframes launch{from{transform:scale(.96)}to{transform:scale(1)}}
</style>
</head>
<body>
<div class="wall">
  <div class="status"><div id="time">--:--</div><div class="right"><span>вЊЃ</span><span>WiвЂ‘Fi</span><span id="controllerState">VR BOX вЂ” РЅРµС‚</span><span id="battery">рџ”‹ --%</span><span class="pill">VR</span></div></div>
  <div class="search" onclick="post('google')"><span class="searchIcon">вЊ•</span><span class="searchText">РџРѕРёСЃРє РІ VR</span><span class="searchHint">Google</span></div>
  <div class="grid">
    <div class="app" data-id="safari"><div class="icon blue"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M15.5 8.5 13 13l-4.5 2.5L11 11z"/></svg></div><span>Safari</span></div>
    <div class="app" data-id="youtube"><div class="icon red"><svg viewBox="0 0 24 24"><path class="solid" d="M21 7.4a2.8 2.8 0 0 0-2-2C17.2 5 12 5 12 5s-5.2 0-7 .4a2.8 2.8 0 0 0-2 2A29 29 0 0 0 2.6 12 29 29 0 0 0 3 16.6a2.8 2.8 0 0 0 2 2c1.8.4 7 .4 7 .4s5.2 0 7-.4a2.8 2.8 0 0 0 2-2 29 29 0 0 0 .4-4.6A29 29 0 0 0 21 7.4Z"/><path d="m10 9 5 3-5 3z" fill="#e21c2a" stroke="none"/></svg></div><span>YouTube</span></div>
    <div class="app" data-id="tiktok"><div class="icon dark"><svg viewBox="0 0 24 24"><path d="M14 5v9a4 4 0 1 1-3.2-3.9"/><path d="M14 5c1.2 2.2 2.8 3.4 5 3.6"/></svg></div><span>TikTok</span></div>
    <div class="app" data-id="telegram"><div class="icon cyan"><svg viewBox="0 0 24 24"><path class="solid" d="M20.8 4.4 3.2 11.2c-1 .4-1 1.1-.2 1.4l4.5 1.4 1.7 5.1c.2.6.1.9.8.9.5 0 .8-.2 1.1-.5l2.1-2 4.4 3.3c.8.4 1.4.2 1.6-.7l3.1-14.4c.3-1.2-.5-1.8-1.5-1.3Z"/></svg></div><span>Telegram</span></div>
    <div class="app" data-id="discord"><div class="icon indigo"><svg viewBox="0 0 24 24"><path d="M7 7.8c2.9-1.1 7.1-1.1 10 0 1.5 1.3 2.3 4.6 1.9 7.6-1.9 1.3-3.7 2-5.5 2.4l-.8-1.1"/><path d="M7 7.8c-1.5 1.3-2.3 4.6-1.9 7.6 1.9 1.3 3.7 2 5.5 2.4l.8-1.1"/><circle cx="9.2" cy="12.5" r="1"/><circle cx="14.8" cy="12.5" r="1"/></svg></div><span>Discord</span></div>
    <div class="app" data-id="spotify"><div class="icon green"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M7 10.2c3.7-1.2 6.8-.9 10 .5"/><path d="M7.8 13c3.1-.8 5.6-.5 8.3.6"/><path d="M8.8 15.5c2.4-.4 4.3-.2 6.4.5"/></svg></div><span>РњСѓР·С‹РєР°</span></div>
    <div class="app" data-id="maps"><div class="icon orange"><svg viewBox="0 0 24 24"><path d="M12 20s6-6 6-10a6 6 0 1 0-12 0c0 4 6 10 6 10Z"/><circle cx="12" cy="10" r="2"/></svg></div><span>РљР°СЂС‚С‹</span></div>
    <div class="app" data-id="gmail"><div class="icon red"><svg viewBox="0 0 24 24"><path d="M4 6h16v12H4z"/><path d="m4 7 8 6 8-6"/></svg></div><span>РџРѕС‡С‚Р°</span></div>
    <div class="app" data-id="google"><div class="icon dark"><svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.2-5.5"/><path d="M20 7v5h-5"/></svg></div><span>Google</span></div>
    <div class="app" data-id="wikipedia"><div class="icon gray"><svg viewBox="0 0 24 24"><path d="M4 6h4l4 10 4-10h4"/><path d="M9 18h6"/></svg></div><span>Wikipedia</span></div>
    <div class="app" data-id="reddit"><div class="icon orange"><svg viewBox="0 0 24 24"><circle cx="12" cy="13" r="6.5"/><circle cx="9.5" cy="12.5" r=".9" fill="#fff" stroke="none"/><circle cx="14.5" cy="12.5" r=".9" fill="#fff" stroke="none"/><path d="M9 15c1.7 1.2 4.3 1.2 6 0"/><path d="m14.5 6 1.8-2.2"/><circle cx="17.2" cy="3.5" r="1"/></svg></div><span>Reddit</span></div>
    <div class="app" data-id="notes"><div class="icon orange"><svg viewBox="0 0 24 24"><path d="M6 4h12v16H6z"/><path d="M9 8h6M9 12h6M9 16h4"/></svg></div><span>Р—Р°РјРµС‚РєРё</span></div>
    <div class="app" data-id="calculator"><div class="icon dark"><svg viewBox="0 0 24 24"><rect x="5" y="3" width="14" height="18" rx="2"/><path d="M8 7h8M8 11h2M12 11h2M16 11h0M8 15h2M12 15h2M8 18h8"/></svg></div><span>РљР°Р»СЊРєСѓР»СЏС‚РѕСЂ</span></div>
    <div class="app" data-id="photos"><div class="icon pink"><svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="4"/><circle cx="12" cy="12" r="3"/><path d="M8 7h1"/></svg></div><span>Р¤РѕС‚Рѕ</span></div>
    <div class="app" data-id="files"><div class="icon blue"><svg viewBox="0 0 24 24"><path d="M4 7h6l2 2h8v9H4z"/><path d="M4 10h16"/></svg></div><span>Р¤Р°Р№Р»С‹</span></div>
    <div class="app" data-id="messages"><div class="icon green"><svg viewBox="0 0 24 24"><path d="M4 5h16v11H9l-5 4z"/></svg></div><span>РЎРѕРѕР±С‰РµРЅРёСЏ</span></div>
    <div class="app" data-id="phone"><div class="icon green"><svg viewBox="0 0 24 24"><path d="M7 4c1.1 0 2 .9 2 2 0 1-.2 1.8-.6 2.6-.2.4-.1.8.2 1.1l2.1 2.1c.3.3.7.4 1.1.2.8-.4 1.6-.6 2.6-.6 1.1 0 2 .9 2 2v3c0 1.1-.9 2-2 2C9.8 18.4 5.6 14.2 4.6 9.1 4.4 8.1 5.2 7 6.3 6.7z"/></svg></div><span>РўРµР»РµС„РѕРЅ</span></div>
    <div class="app" data-id="games"><div class="icon purple"><svg viewBox="0 0 24 24"><rect x="4" y="7" width="16" height="11" rx="3"/><path d="M8 12h4M10 10v4"/><circle cx="16" cy="11.5" r="1" fill="#fff" stroke="none"/><circle cx="18" cy="14.5" r="1" fill="#fff" stroke="none"/></svg></div><span>РРіСЂС‹</span></div>
    <div class="app" data-id="settings"><div class="icon gray"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 0 0-2-1.1L14.3 3h-4.6l-.4 2.7a7 7 0 0 0-2 1.1L5 5.9 3 9.3l2 1.5A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 0 0 2 1.1l.4 2.7h4.6l.4-2.7a7 7 0 0 0 2-1.1l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2Z"/></svg></div><span>РќР°СЃС‚СЂРѕР№РєРё</span></div>
  </div>
  <div class="dock">
    <div class="app" data-id="safari"><div class="icon blue"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M15.5 8.5 13 13l-4.5 2.5L11 11z"/></svg></div></div>
    <div class="app" data-id="youtube"><div class="icon red"><svg viewBox="0 0 24 24"><path d="M5 5h14v14H5z"/><path d="m10 8 5 4-5 4z" fill="#fff" stroke="none"/></svg></div></div>
    <div class="app" data-id="telegram"><div class="icon cyan"><svg viewBox="0 0 24 24"><path d="m5 12 13-6-4 12-3-4-4-1z"/></svg></div></div>
    <div class="app" data-id="messages"><div class="icon green"><svg viewBox="0 0 24 24"><path d="M4 5h16v11H9l-5 4z"/></svg></div></div>
    <div class="app" data-id="settings"><div class="icon gray"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 0 0-2-1.1L14.3 3h-4.6l-.4 2.7a7 7 0 0 0-2 1.1L5 5.9 3 9.3l2 1.5A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 0 0 2 1.1l.4 2.7h4.6l.4-2.7a7 7 0 0 0 2-1.1l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2Z"/></svg></div></div><div class="icon gray"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 0 0-2-1.1L14.3 3h-4.6l-.4 2.7a7 7 0 0 0-2 1.1L5 5.9 3 9.3l2 1.5A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 0 0 2 1.1l.4 2.7h4.6l.4-2.7a7 7 0 0 0 2-1.1l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2Z"/></svg></div></div>
  </div>
  <div class="note">VR Desktop вЂў СЂР°Р±РѕС‡РµРµ РїСЂРѕСЃС‚СЂР°РЅСЃС‚РІРѕ HandAR РІ СЃС‚РµСЂРµРѕ-VR вЂў СЂСѓРєР° / VR BOX</div>
</div>
<script>
function post(id){try{window.webkit.messageHandlers.handarApp.postMessage({id:id});}catch(e){}}
function clock(){const d=new Date();document.getElementById('time').textContent=d.toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});}
setInterval(clock,1000);clock();
document.querySelectorAll('.app').forEach(function(a){a.addEventListener('click',function(){a.classList.add('launch');post(a.dataset.id);setTimeout(()=>a.classList.remove('launch'),320);});});
</script>
</body>
</html>
"""#

    private static func htmlPage(title: String, icon: String, accent: String, body: String, scripts: String = "") -> String {
        let template = #"""
<!doctype html><html lang="ru"><head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta charset="utf-8"><title>HandAR VR App</title>
<style>
:root{--accent:%ACCENT%}
*{box-sizing:border-box}html,body{margin:0;width:100%%;height:100%%;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Helvetica Neue",Arial,sans-serif;background:linear-gradient(135deg,#0d1118,#1a2030);color:#fff}body:before{content:"";position:fixed;inset:0;background:radial-gradient(circle at 70%% 20%%,var(--accent),transparent 42%%);opacity:.28}.wrap{position:relative;height:100%%;padding:22px 34px;display:flex;flex-direction:column;gap:18px}.top{height:44px;display:flex;align-items:center;justify-content:space-between}.brand{display:flex;align-items:center;gap:12px}.back{border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.1);color:#fff;border-radius:15px;padding:10px 15px;font-size:15px}.title{font-size:22px;font-weight:700}.card{flex:1;border:1px solid rgba(255,255,255,.15);background:rgba(255,255,255,.07);backdrop-filter:blur(25px);border-radius:28px;padding:26px;overflow:auto}.hero{display:flex;align-items:center;gap:18px}.bigicon{width:74px;height:74px;border-radius:22px;background:var(--accent);display:flex;align-items:center;justify-content:center;font-size:34px;box-shadow:0 10px 30px rgba(0,0,0,.24)}h1{margin:0;font-size:32px}p{color:rgba(255,255,255,.7);line-height:1.45}.row{display:flex;gap:12px;flex-wrap:wrap}.btn{border:1px solid rgba(255,255,255,.2);background:rgba(255,255,255,.12);color:#fff;border-radius:17px;padding:13px 18px;font-size:15px}.btn.primary{background:var(--accent);border-color:transparent}.small{font-size:12px;color:rgba(255,255,255,.48)}textarea{width:100%%;height:58%%;resize:none;border:1px solid rgba(255,255,255,.18);background:rgba(0,0,0,.2);color:#fff;border-radius:18px;padding:16px;font:inherit;outline:none}.display{font-size:48px;text-align:right;padding:18px;background:rgba(0,0,0,.25);border-radius:20px;margin-bottom:14px}.keys{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}.key{padding:20px 10px;border:0;border-radius:16px;background:rgba(255,255,255,.1);color:#fff;font-size:22px}.key.op{background:var(--accent)}.photo-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:22px}.photo{aspect-ratio:1.25;border-radius:22px;display:flex;align-items:flex-end;padding:14px;font-weight:700;background:linear-gradient(145deg,var(--accent),rgba(255,255,255,.1)),radial-gradient(circle at 70% 25%,#fff5,transparent 35%);border:1px solid rgba(255,255,255,.14)}.p2{filter:saturate(.75)}.p3{filter:hue-rotate(28deg)}.p4{filter:hue-rotate(90deg)}.p5{filter:hue-rotate(145deg)}.p6{filter:hue-rotate(220deg)}.file-list,.chat-list{display:flex;flex-direction:column;gap:10px;margin-top:24px}.file-row,.chat{border:1px solid rgba(255,255,255,.13);background:rgba(255,255,255,.06);color:#fff;border-radius:18px;padding:15px 17px;text-align:left}.file-row{display:grid;grid-template-columns:34px 1fr;gap:3px 10px}.file-row span{grid-row:1/3;font-size:22px}.file-row small{color:rgba(255,255,255,.48)}.chat{display:grid;grid-template-columns:1fr auto;gap:4px 12px}.chat span{color:rgba(255,255,255,.68)}.chat time{grid-column:2;grid-row:1/3;color:rgba(255,255,255,.38);font-size:12px}.phone-display{font-size:36px;letter-spacing:2px;text-align:center;padding:18px;border-radius:18px;background:rgba(0,0,0,.22);margin:22px 0 14px}.phone-keys{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}
</style></head><body><div class="wrap">
<div class="top"><div class="brand"><button class="back" onclick="post('home')">вЂ№ Р”РѕРјРѕР№</button><div class="title">%TITLE%</div></div><div class="small">HandAR VR</div></div>
<div class="card">%BODY%</div></div>
<script>function post(id){try{window.webkit.messageHandlers.handarApp.postMessage({id:id});}catch(e){}}%SCRIPTS%</script>
</body></html>
"""#
        return template
            .replacingOccurrences(of: "%ACCENT%", with: accent)
            .replacingOccurrences(of: "%TITLE%", with: title)
            .replacingOccurrences(of: "%BODY%", with: body)
            .replacingOccurrences(of: "%SCRIPTS%", with: scripts)
            .replacingOccurrences(of: "%%", with: "%")
    }

    private static let vrNotesHTML = htmlPage(
        title: "Р—Р°РјРµС‚РєРё",
        icon: "вњЋ",
        accent: "#f59e0b",
        body: """
<div class="hero"><div class="bigicon">вњЋ</div><div><h1>Р—Р°РјРµС‚РєРё</h1><p>Р›РѕРєР°Р»СЊРЅР°СЏ VR-Р·Р°РјРµС‚РєР° СЃРѕС…СЂР°РЅСЏРµС‚СЃСЏ РЅР° СЌС‚РѕРј СѓСЃС‚СЂРѕР№СЃС‚РІРµ РІРЅСѓС‚СЂРё WebView.</p></div></div>
<textarea id="note" placeholder="РќР°РїРёС€Рё Р·РґРµСЃСЊ..."></textarea>
<div class="row"><button class="btn primary" id="save">РЎРѕС…СЂР°РЅРёС‚СЊ</button><button class="btn" id="clear">РћС‡РёСЃС‚РёС‚СЊ</button></div>
""",
        scripts: """
const note=document.getElementById('note');note.value=localStorage.getItem('handar-note')||'';
document.getElementById('save').onclick=()=>localStorage.setItem('handar-note',note.value);
document.getElementById('clear').onclick=()=>{note.value='';localStorage.removeItem('handar-note');};
"""
    )

    private static let vrCalculatorHTML = htmlPage(
        title: "РљР°Р»СЊРєСѓР»СЏС‚РѕСЂ",
        icon: "пј‹",
        accent: "#4b5563",
        body: """
<div class="display" id="display">0</div><div class="keys">
<button class="key" data-k="7">7</button><button class="key" data-k="8">8</button><button class="key" data-k="9">9</button><button class="key op" data-k="/">Г·</button>
<button class="key" data-k="4">4</button><button class="key" data-k="5">5</button><button class="key" data-k="6">6</button><button class="key op" data-k="*">Г—</button>
<button class="key" data-k="1">1</button><button class="key" data-k="2">2</button><button class="key" data-k="3">3</button><button class="key op" data-k="-">в€’</button>
<button class="key" data-k="0">0</button><button class="key" data-k=".">.</button><button class="key op" data-k="=">=</button><button class="key op" data-k="+">+</button>
</div><div class="row" style="margin-top:14px"><button class="btn" id="clear">РЎР±СЂРѕСЃРёС‚СЊ</button></div>
""",
        scripts: """
let expr='';const d=document.getElementById('display');function render(){d.textContent=expr||'0'}
document.querySelectorAll('[data-k]').forEach(b=>b.onclick=()=>{const k=b.dataset.k;if(k==='='){try{expr=String(Function('return '+expr)())}catch(e){expr='РћС€РёР±РєР°'}}else{expr+=k}render()});document.getElementById('clear').onclick=()=>{expr='';render()};
"""
    )

    private static let vrPhotosHTML = htmlPage(
        title: "Р¤РѕС‚Рѕ",
        icon: "в–¦",
        accent: "#d946ef",
        body: """
<div class="hero"><div class="bigicon">в–¦</div><div><h1>Р¤РѕС‚Рѕ</h1><p>VR-РіР°Р»РµСЂРµСЏ HandAR. Р—РґРµСЃСЊ РјРѕР¶РЅРѕ РїСЂРѕР»РёСЃС‚С‹РІР°С‚СЊ Р»РѕРєР°Р»СЊРЅС‹Рµ СЃРЅРёРјРєРё Р±РµР· РІС‹С…РѕРґР° РёР· VR.</p></div></div>
<div class="photo-grid">
<div class="photo p1">Р—Р°РєР°С‚</div><div class="photo p2">Р“РѕСЂС‹</div><div class="photo p3">Р“РѕСЂРѕРґ</div><div class="photo p4">РњРѕСЂРµ</div><div class="photo p5">РџСѓС‚РµС€РµСЃС‚РІРёРµ</div><div class="photo p6">РР·Р±СЂР°РЅРЅРѕРµ</div>
</div>
""",
        scripts: """
// Р¤РѕС‚Рѕ РІ СЌС‚РѕР№ РґРµРјРѕ-РІРµСЂСЃРёРё РЅР°РјРµСЂРµРЅРЅРѕ Р»РѕРєР°Р»СЊРЅС‹Рµ UI-Р·Р°РіР»СѓС€РєРё: СЃРёСЃС‚РµРјРЅСѓСЋ Р±РёР±Р»РёРѕС‚РµРєСѓ iOS РЅРµР»СЊР·СЏ РІСЃС‚СЂРѕРёС‚СЊ РІРЅСѓС‚СЂСЊ СЃС‚РѕСЂРѕРЅРЅРµРіРѕ WKWebView.
"""
    )

    private static let vrFilesHTML = htmlPage(
        title: "Р¤Р°Р№Р»С‹",
        icon: "в–°",
        accent: "#3b82f6",
        body: """
<div class="hero"><div class="bigicon">в–°</div><div><h1>Р¤Р°Р№Р»С‹</h1><p>VR-С„Р°Р№Р»РѕРІС‹Р№ РјРµРЅРµРґР¶РµСЂ HandAR СЃ РІРёСЂС‚СѓР°Р»СЊРЅС‹РјРё РїР°РїРєР°РјРё РґР»СЏ РєРѕРЅС‚РµРЅС‚Р° С€Р»РµРјР°.</p></div></div>
<div class="file-list">
<button class="file-row"><span>в–±</span><b>РќР° iPhone</b><small>Р›РѕРєР°Р»СЊРЅС‹Рµ РґР°РЅРЅС‹Рµ РїСЂРёР»РѕР¶РµРЅРёСЏ</small></button>
<button class="file-row"><span>в–±</span><b>VR Downloads</b><small>Р—Р°РіСЂСѓР¶РµРЅРЅС‹Рµ РІРµР±-С„Р°Р№Р»С‹</small></button>
<button class="file-row"><span>в–±</span><b>РР·Р±СЂР°РЅРЅРѕРµ</b><small>Р‘С‹СЃС‚СЂС‹Р№ РґРѕСЃС‚СѓРї</small></button>
</div>
"""
    )

    private static let vrMessagesHTML = htmlPage(
        title: "РЎРѕРѕР±С‰РµРЅРёСЏ",
        icon: "вЏ",
        accent: "#22c55e",
        body: """
<div class="hero"><div class="bigicon">вЏ</div><div><h1>РЎРѕРѕР±С‰РµРЅРёСЏ</h1><p>Р’РЅСѓС‚СЂРµРЅРЅРёР№ VR-РёРЅС‚РµСЂС„РµР№СЃ С‡Р°С‚РѕРІ. Р­С‚Рѕ РЅРµ СЃРёСЃС‚РµРјРЅРѕРµ РїСЂРёР»РѕР¶РµРЅРёРµ Messages.</p></div></div>
<div class="chat-list">
<div class="chat"><b>HandAR</b><span>Р”РѕР±СЂРѕ РїРѕР¶Р°Р»РѕРІР°С‚СЊ РІ VR Desktop</span><time>СЃРµР№С‡Р°СЃ</time></div>
<div class="chat"><b>VR Friends</b><span>РќРѕРІС‹Р№ СЃРµР°РЅСЃ РіРѕС‚РѕРІ</span><time>СЃРµРіРѕРґРЅСЏ</time></div>
<div class="chat"><b>Р—Р°РјРµС‚РєРё</b><span>РџСЂРѕРІРµСЂСЊ РЅР°СЃС‚СЂРѕР№РєРё Р»РёРЅР·</span><time>РІС‡РµСЂР°</time></div>
</div>
"""
    )

    private static let vrPhoneHTML = htmlPage(
        title: "РўРµР»РµС„РѕРЅ",
        icon: "вЋ",
        accent: "#22c55e",
        body: """
<div class="hero"><div class="bigicon">вЋ</div><div><h1>РўРµР»РµС„РѕРЅ</h1><p>VR-РЅР°Р±РѕСЂ РЅРѕРјРµСЂР°. Р—РІРѕРЅРѕРє С‡РµСЂРµР· СЃРёСЃС‚РµРјРЅРѕРµ РїСЂРёР»РѕР¶РµРЅРёРµ Р·РґРµСЃСЊ РЅРµ РІСЃС‚СЂР°РёРІР°РµС‚СЃСЏ.</p></div></div>
<div class="phone-display" id="phone-display">вЊ•</div>
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
        title: "РРіСЂС‹",
        icon: "рџЋ®",
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
    <div class="gamebar"><h2>VR Arcade</h2><button class="gamebtn" onclick="post('home')">Р Р°Р±РѕС‡РёР№ СЃС‚РѕР»</button></div>
    <div class="gamecardgrid">
      <div class="gamecard" onclick="startFruit()"><div><div class="gameemoji">рџЌ‰рџЌ“</div><h3>Fruit Slice VR</h3><p>РўРІРѕСЏ РІРµСЂСЃРёСЏ РёРіСЂС‹ СЃ РЅР°СЂРµР·РєРѕР№ С„СЂСѓРєС‚РѕРІ. Р”РІРёРіР°Р№ СЂСѓРєРѕР№ Рё СЂРµР¶СЊ Р»РµС‚СЏС‰РёРµ С„СЂСѓРєС‚С‹, РёР·Р±РµРіР°СЏ Р±РѕРјР±.</p><span class="tag">Р СѓРєР° + pinch</span></div><div>в–¶ РРіСЂР°С‚СЊ</div></div>
      <div class="gamecard" onclick="startNeon()"><div><div class="gameemoji">в„пёЏвњЁ</div><h3>Neon Dodge</h3><p>Р”РµСЂР¶Рё СѓРєР°Р·Р°С‚РµР»СЊ РїРѕРґР°Р»СЊС€Рµ РѕС‚ РјРµС‚РµРѕСЂРѕРІ Рё РїСЂРѕРґРµСЂР¶РёСЃСЊ 30 СЃРµРєСѓРЅРґ, СЃРѕР±РёСЂР°СЏ РѕС‡РєРё.</p><span class="tag">Р СѓРєР° + РґРІРёР¶РµРЅРёРµ</span></div><div>в–¶ РРіСЂР°С‚СЊ</div></div>
      <div class="gamecard" onclick="startStack()"><div><div class="gameemoji">рџ§±рџЏ—пёЏ</div><h3>Stack Rush</h3><p>РўРѕС‡РЅРѕ СЃС‚Р°РІСЊ РґРІРёР¶СѓС‰РёРµСЃСЏ Р±Р»РѕРєРё РґСЂСѓРі РЅР° РґСЂСѓРіР° Рё СЃС‚СЂРѕР№ Р±Р°С€РЅСЋ РєР°Рє РјРѕР¶РЅРѕ РІС‹С€Рµ.</p><span class="tag">Р СѓРєР° + pinch</span></div><div>в–¶ РРіСЂР°С‚СЊ</div></div>
    </div>
  </section>
  <section id="fruitScreen" class="screen"><div class="gamebar"><h2>Fruit Slice VR</h2><div class="score">рџЌ‰ <span id="fruitScore">0</span> &nbsp; вќ¤пёЏ <span id="fruitLives">3</span></div><button class="gamebtn" onclick="showHome()">в†ђ РРіСЂС‹</button></div><div class="arena"><canvas id="fruitCanvas"></canvas><div class="help">РЎРѕР¶РјРё Р±РѕР»СЊС€РѕР№ РїР°Р»РµС† СЃ СѓРєР°Р·Р°С‚РµР»СЊРЅС‹Рј Рё РїСЂРѕРІРµРґРё С‡РµСЂРµР· С„СЂСѓРєС‚. Р‘РѕРјР±С‹ СЂРµР¶СЊ РЅРµР»СЊР·СЏ.</div></div></section>
  <section id="neonScreen" class="screen"><div class="gamebar"><h2>Neon Dodge</h2><div class="score">вљЎ <span id="neonScore">0</span> &nbsp; вЏ± <span id="neonTime">30</span></div><button class="gamebtn" onclick="showHome()">в†ђ РРіСЂС‹</button></div><div class="arena"><canvas id="neonCanvas"></canvas><div class="help">Р”РІРёРіР°Р№ СѓРєР°Р·Р°С‚РµР»РµРј СЂСѓРєРѕР№. РќРµ СЃС‚Р°Р»РєРёРІР°Р№СЃСЏ СЃ РіРѕР»СѓР±С‹РјРё РјРµС‚РµРѕСЂР°РјРё.</div></div></section>
  <section id="stackScreen" class="screen"><div class="gamebar"><h2>Stack Rush</h2><div class="score">рџЏ—пёЏ <span id="stackHeight">0</span></div><button class="gamebtn" onclick="showHome()">в†ђ РРіСЂС‹</button></div><div class="arena"><canvas id="stackCanvas"></canvas><div class="help">РЎР»РµРґРё Р·Р° Р±Р»РѕРєРѕРј Рё СЃРґРµР»Р°Р№ pinch, РєРѕРіРґР° РѕРЅ СЃРѕРІРїР°РґС‘С‚ СЃ РїСЂРµРґС‹РґСѓС‰РёРј.</div></div></section>
  <div id="gameOverlay"><div class="overlayBox"><h2 id="overTitle">Р“РѕС‚РѕРІРѕ</h2><p id="overText"></p><button class="gamebtn primary" onclick="resetCurrent()">Р—Р°РЅРѕРІРѕ</button></div></div>
</div>
<div class="row" style="margin-top:14px"><button class="btn primary" onclick="post('home')">РќР° СЂР°Р±РѕС‡РёР№ СЃС‚РѕР»</button></div>
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
const fruitSet=[['рџЌ‰',30],['рџЌЉ',25],['рџЌ“',20],['рџЌЋ',22],['рџЌЌ',35],['рџҐќ',24],['рџЌ‹',18]];
function fruitAdd(){const d=devicePixelRatio||1;const [e,p]=fruitSet[(Math.random()*fruitSet.length)|0];fruitItems.push({x:55+Math.random()*(fruitW-110),y:fruitH+40,vx:(Math.random()-.5)*3.2,vy:-11-Math.random()*5,r:28+Math.random()*9,e,p,b:Math.random()<.10});}
function fruitMove(e){const p=pointerPos(fc,e),q=fruitTrail.length?fruitTrail[fruitTrail.length-1]:p;fruitTrail.push(p);if(fruitTrail.length>12)fruitTrail.shift();if(pressed)fruitSlice(q,p)}
function fruitSlice(a,b){for(let i=fruitItems.length-1;i>=0;i--){const o=fruitItems[i],abx=b.x-a.x,aby=b.y-a.y,t=Math.max(0,Math.min(1,((o.x-a.x)*abx+(o.y-a.y)*aby)/(abx*abx+aby*aby||1))),px=a.x+t*abx,py=a.y+t*aby;if(Math.hypot(o.x-px,o.y-py)<o.r+10){if(o.b){fruitLives--;document.getElementById('fruitLives').textContent=fruitLives;if(fruitLives<=0){fruitRunning=false;overlay('Р¤СЂСѓРєС‚С‹ Р·Р°РєРѕРЅС‡РёР»РёСЃСЊ','РЎС‡С‘С‚: '+fruitScore);}}else fruitScore+=o.p;document.getElementById('fruitScore').textContent=fruitScore;fruitItems.splice(i,1);}}}
function fruitLoop(t){if(!fruitRunning)return;const d=devicePixelRatio||1;fx.setTransform(d,0,0,d,0,0);fx.clearRect(0,0,fruitW,fruitH);fruitSpawn-=t-fruitLast;fruitLast=t;if(fruitSpawn<=0){fruitAdd();if(Math.random()<.35)fruitAdd();fruitSpawn=580+Math.random()*430}for(let i=fruitItems.length-1;i>=0;i--){const o=fruitItems[i];o.x+=o.vx;o.vy+=.42;o.y+=o.vy;fx.save();fx.translate(o.x,o.y);fx.font=(o.r*2)+'px system-ui';fx.textAlign='center';fx.textBaseline='middle';fx.shadowBlur=18;fx.shadowColor=o.b?'#ef4444':'#ffd34d';fx.fillText(o.b?'рџ’Ј':o.e,0,0);fx.restore();if(o.y>fruitH+70){if(!o.b)fruitLives--;fruitItems.splice(i,1);document.getElementById('fruitLives').textContent=fruitLives;if(fruitLives<=0){fruitRunning=false;overlay('Р¤СЂСѓРєС‚С‹ Р·Р°РєРѕРЅС‡РёР»РёСЃСЊ','РЎС‡С‘С‚: '+fruitScore);}}}fruitTrail.forEach((p,i)=>{if(i===0)return;const q=fruitTrail[i-1];fx.strokeStyle='rgba(255,255,255,'+(i/fruitTrail.length*.75)+')';fx.lineWidth=3+i*.35;fx.lineCap='round';fx.beginPath();fx.moveTo(q.x,q.y);fx.lineTo(p.x,p.y);fx.stroke()});requestAnimationFrame(fruitLoop)}
fc.addEventListener('pointermove',fruitMove);fc.addEventListener('pointerdown',e=>{pressed=true;fruitMove(e)});window.addEventListener('pointerup',()=>pressed=false);
// Neon Dodge
const nc=document.getElementById('neonCanvas'),nx=nc.getContext('2d');let neonRunning=false,neonObs=[],neonScore=0,neonStart=0,neonW=1,neonH=1,neonP={x:.5,y:.5};
function startNeon(){show('neon');[neonW,neonH]=fitCanvas(nc);neonRunning=true;neonObs=[];neonScore=0;neonStart=performance.now();document.getElementById('neonScore').textContent='0';requestAnimationFrame(neonLoop)}
function neonMove(e){const p=pointerPos(nc,e);neonP={x:p.x/neonW,y:p.y/neonH}}
function neonLoop(t){if(!neonRunning)return;const d=devicePixelRatio||1;nx.setTransform(d,0,0,d,0,0);nx.clearRect(0,0,neonW,neonH);const elapsed=t-neonStart,left=Math.max(0,30000-elapsed);document.getElementById('neonTime').textContent=Math.ceil(left/1000);if(left<=0){neonRunning=false;overlay('Р Р°СѓРЅРґ РѕРєРѕРЅС‡РµРЅ','РЎС‡С‘С‚: '+neonScore);return}if(Math.random()<.045)neonObs.push({x:Math.random()*neonW,y:-25,r:11+Math.random()*15,v:2.8+Math.random()*4});const px=neonP.x*neonW,py=neonP.y*neonH;for(let i=neonObs.length-1;i>=0;i--){const o=neonObs[i];o.y+=o.v;if(Math.hypot(o.x-px,o.y-py)<o.r+23){neonRunning=false;overlay('РџРѕРїР°РґР°РЅРёРµ!','РЎС‡С‘С‚: '+neonScore);return}if(o.y>neonH+40){neonObs.splice(i,1);neonScore++;document.getElementById('neonScore').textContent=neonScore}}nx.strokeStyle='rgba(34,211,238,.16)';for(let i=0;i<16;i++){const a=i*Math.PI/8;nx.beginPath();nx.moveTo(px,py);nx.lineTo(px+Math.cos(a)*Math.max(neonW,neonH),py+Math.sin(a)*Math.max(neonW,neonH));nx.stroke()}neonObs.forEach(o=>{nx.beginPath();nx.fillStyle='#38bdf8';nx.shadowBlur=24;nx.shadowColor='#22d3ee';nx.arc(o.x,o.y,o.r,0,Math.PI*2);nx.fill()});nx.shadowBlur=0;nx.beginPath();nx.fillStyle='#fff';nx.arc(px,py,17,0,Math.PI*2);nx.fill();nx.strokeStyle='#67e8f9';nx.lineWidth=4;nx.stroke();requestAnimationFrame(neonLoop)}
nc.addEventListener('pointermove',neonMove);nc.addEventListener('pointerdown',neonMove);
// Stack Rush
const sc=document.getElementById('stackCanvas'),sx=sc.getContext('2d');let stackRunning=false,stackBlocks=[],stackMoving=null,stackDir=1,stackW=1,stackH=1,stackHeight=0,stackPhase=0;
function startStack(){show('stack');[stackW,stackH]=fitCanvas(sc);stackRunning=true;stackHeight=0;document.getElementById('stackHeight').textContent='0';stackBlocks=[{x:stackW/2-110,y:stackH-50,w:220,h:32}];stackMoving={x:0,y:stackH-86,w:220,h:32};stackPhase=0;requestAnimationFrame(stackLoop)}
function stackMove(e){const p=pointerPos(sc,e);stackPhase=p.x/stackW;if(stackMoving&&stackRunning)stackMoving.x=Math.max(0,Math.min(stackW-stackMoving.w,p.x-stackMoving.w/2))}
function stackCut(){if(!stackRunning||!stackMoving)return;const top=stackBlocks[stackBlocks.length-1],l=Math.max(top.x,stackMoving.x),r=Math.min(top.x+top.w,stackMoving.x+stackMoving.w);if(r-l<26){stackRunning=false;overlay('Р‘Р°С€РЅСЏ СѓРїР°Р»Р°','Р’С‹СЃРѕС‚Р°: '+stackHeight);return}const nw=r-l;stackBlocks.push({x:l,y:top.y-36,w:nw,h:32});stackMoving={x:0,y:top.y-72,w:nw,h:32};stackHeight++;document.getElementById('stackHeight').textContent=stackHeight}
function stackLoop(){if(!stackRunning)return;const d=devicePixelRatio||1;sx.setTransform(d,0,0,d,0,0);sx.clearRect(0,0,stackW,stackH);if(stackMoving){stackMoving.x+=stackDir*(3.5+Math.min(6,stackHeight*.12));if(stackMoving.x<=0){stackMoving.x=0;stackDir=1}if(stackMoving.x+stackMoving.w>=stackW){stackMoving.x=stackW-stackMoving.w;stackDir=-1}}stackBlocks.forEach((b,i)=>{sx.fillStyle=i%2?'#fbbf24':'#fb923c';sx.shadowBlur=16;sx.shadowColor='#f59e0b';sx.fillRect(b.x,b.y,b.w,b.h);sx.shadowBlur=0;sx.fillStyle='rgba(255,255,255,.25)';sx.fillRect(b.x,b.y,b.w,3)});if(stackMoving){sx.fillStyle='#fde68a';sx.fillRect(stackMoving.x,stackMoving.y,stackMoving.w,stackMoving.h)}requestAnimationFrame(stackLoop)}
sc.addEventListener('pointermove',stackMove);sc.addEventListener('pointerdown',e=>{stackMove(e);stackCut()});
addEventListener('resize',()=>{if(current==='fruit')[fruitW,fruitH]=fitCanvas(fc);if(current==='neon')[neonW,neonH]=fitCanvas(nc);if(current==='stack')[stackW,stackH]=fitCanvas(sc)});
"""
    )
    private static let vrSettingsHTML = htmlPage(
        title: "РќР°СЃС‚СЂРѕР№РєРё",
        icon: "вљ™",
        accent: "#6b7280",
        body: """
<div class="hero"><div class="bigicon">вљ™</div><div><h1>VR Settings</h1><p>Р‘С‹СЃС‚СЂС‹Рµ РґРµР№СЃС‚РІРёСЏ РґР»СЏ С€Р»РµРјР°. РџРѕРґСЂРѕР±РЅР°СЏ С„РёР·РёС‡РµСЃРєР°СЏ РєР°Р»РёР±СЂРѕРІРєР° РѕСЃС‚Р°С‘С‚СЃСЏ РІ РѕР±С‹С‡РЅРѕРј РјРµРЅСЋ HandAR.</p></div></div>
<div class="row"><button class="btn primary" onclick="post('center')">РџРµСЂРµС†РµРЅС‚СЂРёСЂРѕРІР°С‚СЊ СЌРєСЂР°РЅ</button><button class="btn" onclick="post('controller-diagnostics')">Р”РёР°РіРЅРѕСЃС‚РёРєР° VR BOX</button><button class="btn" onclick="post('exit')">Р’С‹Р№С‚Рё РёР· VR</button></div>
<div style="margin-top:24px"><p><b>Рћ РєРѕРЅС‚СЂРѕР»Р»РµСЂРµ:</b> РїСЂРёР»РѕР¶РµРЅРёРµ РїС‹С‚Р°РµС‚СЃСЏ РїРѕР»СѓС‡Р°С‚СЊ Game Controller Рё motion-РїСЂРѕС„РёР»СЊ. Р•СЃР»Рё iOS РЅРµ РѕС‚РґР°С‘С‚ VR BOX РєР°Рє РєРѕРЅС‚СЂРѕР»Р»РµСЂ, СЌС‚РѕС‚ СЂРµР¶РёРј РЅРµ РјРѕР¶РµС‚ РёР·РѕР±СЂРµСЃС‚Рё РµРіРѕ СЃРёРіРЅР°Р»С‹.</p><p class="small">РќР°С‚РёРІРЅС‹Рµ СЃС‚РѕСЂРѕРЅРЅРёРµ iPhone-РїСЂРёР»РѕР¶РµРЅРёСЏ РЅРµР»СЊР·СЏ РІСЃС‚СЂРѕРёС‚СЊ РІРЅСѓС‚СЂСЊ РѕРєРЅР° HandAR. РџРѕСЌС‚РѕРјСѓ Р·РЅР°С‡РєРё РЅР° VR Desktop РѕС‚РєСЂС‹РІР°СЋС‚ VR-РІРµСЂСЃРёРё РЅР° Р±Р°Р·Рµ WKWebView. РЎРёСЃС‚РµРјРЅС‹Р№ iOS Р·Р°РїСѓСЃРє РІРѕР·РјРѕР¶РµРЅ С‚РѕР»СЊРєРѕ РєР°Рє РѕС‚РґРµР»СЊРЅС‹Р№ РїРµСЂРµС…РѕРґ РёР· РїСЂРёР»РѕР¶РµРЅРёСЏ.</p></div>
"""
    )

    private func openVRDesktop() {
        isCinemaMode = false
        browserWorldWidth = Self.defaultPanelWidth
        browserWorldHeight = Self.defaultPanelHeight
        updatePanelSize(width: browserWorldWidth)
        toolbarNode.isHidden = false
        browser.loadHTMLString(Self.vrDesktopHTML, baseURL: URL(string: "https://handar.vision/"))
    }

    private func openVRApp(id: String) {
        isCinemaMode = false
        browserWorldWidth = Self.defaultPanelWidth
        browserWorldHeight = Self.defaultPanelHeight
        updatePanelSize(width: browserWorldWidth)
        toolbarNode.isHidden = false
        switch id {
        case "home":
            openVRDesktop()
        case "safari", "google":
            browser.load(URLRequest(url: Self.homeURL))
        case "youtube":
            browser.load(URLRequest(url: Self.youTubeURL))
        case "tiktok":
            browser.load(URLRequest(url: Self.tikTokURL))
        case "telegram":
            browser.load(URLRequest(url: Self.telegramURL))
        case "discord":
            browser.load(URLRequest(url: Self.discordURL))
        case "spotify":
            browser.load(URLRequest(url: Self.spotifyURL))
        case "maps":
            browser.load(URLRequest(url: Self.mapsURL))
        case "gmail":
            browser.load(URLRequest(url: Self.gmailURL))
        case "reddit":
            browser.load(URLRequest(url: Self.redditURL))
        case "wikipedia":
            browser.load(URLRequest(url: Self.wikipediaURL))
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
        case "settings":
            browser.loadHTMLString(Self.vrSettingsHTML, baseURL: URL(string: "https://handar.vision/"))
        default:
            openVRDesktop()
        }
    }

    private func handleVRSystemAction(_ action: String) {
        switch action {
        case "home": openVRDesktop()
        case "center": resetBrowserAnchor()
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


/// Black overlay with two transparent circular holes. It creates the VR-lens
/// silhouette without applying a Core Animation mask to the WKWebView layers,
/// which can interfere with hardware-decoded HTML5 video presentation.
/// Р’РёСЂС‚СѓР°Р»СЊРЅР°СЏ СЂСѓРєР° РїРѕРІРµСЂС… РЅР°СЃС‚РѕСЏС‰РµР№: СЂРёСЃСѓРµРј Р»Р°РґРѕРЅСЊ РїР»СЋСЃ Р±Р°С‚Р°СЂРµСЋ РїР°Р»СЊС†РµРІ
/// СЃ СЃСѓР¶РµРЅРёРµРј Рє РєРѕРЅС‡РёРєР°Рј, РёСЃРїРѕР»СЊР·СѓСЏ С‚Рµ Р¶Рµ СЃСѓСЃС‚Р°РІС‹, С‡С‚Рѕ Рё С‚СЂРµРєРµСЂ.
final class DirectVideoLensMaskView: UIView {
    var leftCircle: CGRect = .zero { didSet { setNeedsDisplay() } }
    var rightCircle: CGRect = .zero { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.black.cgColor)
        context.addRect(bounds)
        if leftCircle.width > 1 && leftCircle.height > 1 {
            context.addEllipse(in: leftCircle)
        }
        if rightCircle.width > 1 && rightCircle.height > 1 {
            context.addEllipse(in: rightCircle)
        }
        context.drawPath(using: .eoFill)
    }
}


private extension MainViewController {
    func updateVRDesktopStatus() {
        let battery = UIDevice.current.batteryLevel
        let batteryText = battery >= 0 ? String(format: "%.0f%%", battery * 100) : "вЂ”"
        let controllerText = controllerConnected ? "VR BOX" : "VR BOX вЂ” РЅРµС‚"
        let script = """
(function(){
  var b=document.getElementById('battery'); if(b) b.textContent='рџ”‹ \(batteryText)';
  var c=document.getElementById('controllerState'); if(c) c.textContent='\(controllerText)';
})();
"""
        browser.evaluateJavaScript(script, completionHandler: nil)
    }
}

extension MainViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if directVideoActive, webView === directVideoLeft || webView === directVideoRight {
            webView.evaluateJavaScript("window.__handarTuneDirectVideo ? window.__handarTuneDirectVideo() : null;", completionHandler: nil)
            if webView === directVideoLeft {
                activateDirectVideoAudio()
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
    private var latestFrame: ARFrame?
    private var interfaceOrientation: UIInterfaceOrientation = .landscapeRight

    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?
    var onCamera: ((ARFrame) -> Void)?
    var onAnchorUpdate: ((ARAnchor) -> Void)?
    var onFailure: ((String) -> Void)?

    var latestFrameCopy: ARFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        interfaceOrientation = orientation
    }

    /// РњР°С‚СЂРёС†Р° РіРѕР»РѕРІС‹ РІ РјРёСЂРµ СЃ РїРѕРїСЂР°РІРєРѕР№ РЅР° РѕСЂРёРµРЅС‚Р°С†РёСЋ РёРЅС‚РµСЂС„РµР№СЃР°.
    func headTransform(_ frame: ARFrame) -> simd_float4x4 {
        frame.camera.viewMatrix(for: interfaceOrientation).inverse
    }

    /// Р›СѓС‡ РёР· С‚РѕС‡РєРё, РЅР°Р№РґРµРЅРЅРѕР№ Vision, РІ РјРёСЂРѕРІС‹Рµ РєРѕРѕСЂРґРёРЅР°С‚С‹.
    /// РЎС‡РёС‚Р°РµРј С‡РµСЂРµР· РёРЅС‚СЂРёРЅСЃРёРєРё РєР°РјРµСЂС‹: РЅРёРєР°РєРѕРіРѕ СЃРѕРіР»Р°СЃРѕРІР°РЅРёСЏ РІСЊСЋРїРѕСЂС‚РѕРІ.
    func worldRay(visionPoint: CGPoint) -> WorldRay? {
        guard let frame = latestFrameCopy else { return nil }

        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]
        guard fx > 0, fy > 0 else { return nil }

        // Vision РѕС‚РґР°С‘С‚ РЅРѕСЂРјРёСЂРѕРІР°РЅРЅС‹Рµ РєРѕРѕСЂРґРёРЅР°С‚С‹ РѕСЂРёРµРЅС‚РёСЂРѕРІР°РЅРЅРѕРіРѕ РєР°РґСЂР°
        // (РЅР°С‡Р°Р»Рѕ вЂ” Р»РµРІС‹Р№ РЅРёР·). Р’РѕР·РІСЂР°С‰Р°РµРјСЃСЏ РІ РєРѕРѕСЂРґРёРЅР°С‚С‹ СЃС‹СЂРѕРіРѕ РєР°РґСЂР°.
        let flipped = (interfaceOrientation == .landscapeLeft)
        let px = Float(flipped ? (1 - visionPoint.x) : visionPoint.x) * Float(resolution.width)
        let py = Float(flipped ? visionPoint.y : (1 - visionPoint.y)) * Float(resolution.height)
        guard px.isFinite, py.isFinite else { return nil }

        let directionInCamera = simd_normalize(SIMD3<Float>(
            (px - cx) / fx,
            -(py - cy) / fy,
            -1
        ))

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

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            onFailure?("Р­С‚РѕС‚ iPhone РЅРµ РїРѕРґРґРµСЂР¶РёРІР°РµС‚ ARKit World Tracking.")
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        configuration.planeDetection = []
        configuration.environmentTexturing = ARWorldTrackingConfiguration.EnvironmentTexturing.none

        // Р РµРєРѕРЅСЃС‚СЂСѓРєС†РёСЏ СЃС†РµРЅС‹ Рё С‚РµРєСЃС‚СѓСЂРёСЂРѕРІР°РЅРёРµ РѕРєСЂСѓР¶РµРЅРёСЏ СЃС‚РѕСЏС‚ РєР°РґСЂРѕРІ,
        // Р° РІ СЃС‚РµСЂРµРѕСЂРµР¶РёРјРµ Р±СЋРґР¶РµС‚ РєР°РґСЂР° РІР°Р¶РЅРµРµ.
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
    }

    func add(anchor: ARAnchor) {
        session.add(anchor: anchor)
    }

    func remove(anchor: ARAnchor) {
        session.remove(anchor: anchor)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameLock.lock()
        latestFrame = frame
        frameLock.unlock()

        onFrame?(frame.capturedImage, imageOrientation(for: interfaceOrientation))
        onCamera?(frame)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        anchors.forEach { onAnchorUpdate?($0) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onFailure?("ARKit Р·Р°РІРµСЂС€РёР» СЃРµСЃСЃРёСЋ: \(error.localizedDescription)")
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

// MARK: - РћС‚СЃР»РµР¶РёРІР°РЅРёРµ СЂСѓРєРё ----------------------------------------------------

final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        if let latest = VNDetectHumanHandPoseRequest.supportedRevisions.max() {
            request.revision = latest
        }
        return request
    }()

    private let queue = DispatchQueue(label: "handar.vision", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)

    /// РЎРіР»Р°Р¶РµРЅРЅС‹Рµ РїРѕР·РёС†РёРё Рё СЃРѕСЃС‚РѕСЏРЅРёСЏ С‰РёРїРєРѕРІ РїРѕ РєР°Р¶РґРѕР№ СЂСѓРєРµ.
    private struct HandState {
        var index: CGPoint?
        var middle: CGPoint?
        var thumb: CGPoint?
        var joints: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        /// РЎРєРѕР»СЊРєРѕ РєР°РґСЂРѕРІ РїРѕРґСЂСЏРґ СЃСѓСЃС‚Р°РІ РЅРµ СЂР°СЃРїРѕР·РЅР°С‘С‚СЃСЏ вЂ” РїРѕРєР° Р»РёРјРёС‚ РЅРµ РІС‹С€РµР»,
        /// РІРёСЂС‚СѓР°Р»СЊРЅС‹Р№ СЃСѓСЃС‚Р°РІ РґРµСЂР¶РёС‚ РїРѕСЃР»РµРґРЅСЋСЋ СЃС‚Р°Р±РёР»СЊРЅСѓСЋ РїРѕР·РёС†РёСЋ.
        var jointAges: [VNHumanHandPoseObservation.JointName: Int] = [:]
        var isFist = false
        var clickPinch = false
        var grabPinch = false

        mutating func reset() {
            index = nil
            middle = nil
            thumb = nil
            joints.removeAll(keepingCapacity: true)
            jointAges.removeAll(keepingCapacity: true)
            isFist = false
            clickPinch = false
            grabPinch = false
        }
    }

    private var leftState = HandState()
    private var rightState = HandState()

    var onUpdate: ((HandSample?, HandSample?) -> Void)?

    func process(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        guard gate.wait(timeout: .now()) == .success else { return }

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.gate.signal() }

            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation,
                options: [:]
            )

            do {
                try handler.perform([self.request])

                var left: HandSample?
                var right: HandSample?
                var foundLeft = false
                var foundRight = false

                for observation in self.request.results ?? [] {
                    guard
                        let allPoints = try? observation.recognizedPoints(.all),
                        let index = allPoints[.indexTip],
                        let thumb = allPoints[.thumbTip],
                        let wrist = allPoints[.wrist],
                        index.confidence > 0.45,
                        thumb.confidence > 0.45,
                        wrist.confidence > 0.35
                    else {
                        continue
                    }

                    let isLeft = observation.chirality == .left
                    var state = isLeft ? self.leftState : self.rightState

                    var filteredJoints: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
                    filteredJoints.reserveCapacity(allPoints.count)
                    for (jointName, point) in allPoints where point.confidence > 0.32 {
                        filteredJoints[jointName] = smooth(
                            state.joints[jointName],
                            point.location,
                            alpha: adaptiveAlpha(previous: state.joints[jointName], current: point.location)
                        )
                        state.jointAges[jointName] = 0
                    }

                    // РџСЂРѕРїР°РІС€РёРµ СЃСѓСЃС‚Р°РІС‹ (РїР°Р»РµС† Р·Р° РїР°Р»СЊС†РµРј, РІ С‚РµРЅРё) РЅРµ С‚РµР»РµРїРѕСЂС‚РёСЂСѓСЋС‚
                    // РІРёСЂС‚СѓР°Р»СЊРЅСѓСЋ СЂСѓРєСѓ вЂ” РґРµСЂР¶РёРј РїРѕСЃР»РµРґРЅСЋСЋ СЃС‚Р°Р±РёР»СЊРЅСѓСЋ РїРѕР·РёС†РёСЋ
                    // РґРѕ Р»РёРјРёС‚Р° РєР°РґСЂРѕРІ, РёРЅР°С‡Рµ СЃРєСЂС‹РІР°РµРј СѓР·РµР».
                    for (jointName, old) in state.joints {
                        guard filteredJoints[jointName] == nil else { continue }
                        let age = (state.jointAges[jointName] ?? 0) + 1
                        state.jointAges[jointName] = age
                        if age <= 18 {
                            filteredJoints[jointName] = old
                        }
                    }

                    // РљСѓР»Р°Рє: СЃС‡РёС‚Р°РµРј СЃРѕРіРЅСѓС‚С‹Рµ РїР°Р»СЊС†С‹ РїРѕ СѓРіР»Сѓ РІ PIP.
                    let fingerTriplets: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
                        (.indexMCP, .indexPIP, .indexDIP),
                        (.middleMCP, .middlePIP, .middleDIP),
                        (.ringMCP, .ringPIP, .ringDIP),
                        (.littleMCP, .littlePIP, .littleDIP)
                    ]
                    var curled = 0
                    var known = 0
                    for (mcp, pip, dip) in fingerTriplets {
                        if let isCurled = fingerCurled(
                            mcp: filteredJoints[mcp],
                            pip: filteredJoints[pip],
                            dip: filteredJoints[dip]
                        ) {
                            known += 1
                            if isCurled { curled += 1 }
                        }
                    }
                    if known >= 2 {
                        if curled >= 3 {
                            state.isFist = true
                        } else if curled <= 1 {
                            state.isFist = false
                        }
                    }

                    let filteredIndex = filteredJoints[.indexTip] ?? index.location
                    let filteredMiddle = filteredJoints[.middleTip]
                    let filteredThumb = filteredJoints[.thumbTip] ?? thumb.location
                    let filteredWrist = filteredJoints[.wrist] ?? wrist.location
                    let indexBase = filteredJoints[.indexMCP]
                    let middleBase = filteredJoints[.middleMCP]

                    // РќРѕСЂРјРёСЂСѓРµРј РЅР° Р»Р°РґРѕРЅСЊ, РЅРѕ РЅРµ С‚СЂРµР±СѓРµРј РёРґРµР°Р»СЊРЅРѕРіРѕ СЂР°СЃРїРѕР·РЅР°РІР°РЅРёСЏ
                    // СЃСЂРµРґРЅРµРіРѕ РїР°Р»СЊС†Р° РєР°Р¶РґС‹Р№ РєР°РґСЂ. РўР°Рє РєСѓСЂСЃРѕСЂ РѕСЃС‚Р°С‘С‚СЃСЏ СЃС‚Р°Р±РёР»СЊРЅС‹Рј,
                    // Р° СЃСЂРµРґРЅРёР№+Р±РѕР»СЊС€РѕР№ РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ С‚РѕР»СЊРєРѕ РєР°Рє РєРѕРјР°РЅРґР° РєР»РёРєР°.
                    let palmReference = indexBase ?? middleBase ?? filteredWrist
                    let palmSize = max(distance(filteredWrist, palmReference), 0.035)
                    let clickRatio = filteredMiddle.map { distance($0, filteredThumb) / palmSize }
                    let grabRatio = distance(filteredIndex, filteredThumb) / palmSize

                    state.index = filteredIndex
                    state.middle = filteredMiddle
                    state.thumb = filteredThumb
                    state.joints = filteredJoints
                    state.clickPinch = clickRatio.map {
                        pinchHysteresis(previous: state.clickPinch, ratio: $0, close: 0.52, open: 0.70)
                    } ?? false
                    state.grabPinch = pinchHysteresis(previous: state.grabPinch, ratio: grabRatio, close: 0.46, open: 0.64)

                    let sample = HandSample(
                        indexTip: filteredIndex,
                        middleTip: filteredMiddle ?? filteredIndex,
                        thumbTip: filteredThumb,
                        joints: filteredJoints,
                        clickPinch: state.clickPinch,
                        grabPinch: state.grabPinch,
                        isFist: state.isFist
                    )

                    if isLeft {
                        self.leftState = state
                        foundLeft = true
                        left = sample
                    } else {
                        self.rightState = state
                        foundRight = true
                        right = sample
                    }
                }

                if !foundLeft { self.leftState.reset() }
                if !foundRight { self.rightState.reset() }

                self.onUpdate?(left, right)
            } catch {
                self.leftState.reset()
                self.rightState.reset()
                self.onUpdate?(nil, nil)
            }
        }
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
private func pinchHysteresis(
    previous: Bool,
    ratio: CGFloat,
    close: CGFloat = 0.52,
    open: CGFloat = 0.70
) -> Bool {
    if previous { return ratio < open }
    return ratio < close
}

@inline(__always)
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

/// РџР°Р»РµС† СЃРѕРіРЅСѓС‚, РµСЃР»Рё СѓРіРѕР» РјРµР¶РґСѓ СЃРµРіРјРµРЅС‚Р°РјРё MCPв†’PIP Рё PIPв†’DIP Р±РѕР»СЊС€Рµ ~80В°.
/// nil вЂ” СЃСѓСЃС‚Р°РІ РЅРµ РІРёРґРµРЅ, РІРµСЂРґРёРєС‚ РЅРµ РІС‹РґР°С‘Рј.
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
    return acos(cosAngle) > 1.40 // ~80В°
}

// MARK: - Р’РІРѕРґ РІ СЃС‚СЂР°РЅРёС†Сѓ ------------------------------------------------------

final class WebInputBridge {
    private var lastPoint: CGPoint?
    private var pointerDown = false

    func update(normalizedPoint: CGPoint, pinch: Bool, webView: WKWebView) {
        let x = normalizedPoint.x * webView.bounds.width
        let y = normalizedPoint.y * webView.bounds.height
        let current = CGPoint(x: x, y: y)
        let previous = lastPoint ?? current
        let deltaY = current.y - previous.y

        if pinch && !pointerDown {
            pointerDown = true
            dispatch("window.__handarPointerDown(\(x),\(y),1);", to: webView)
        } else if pinch && pointerDown {
            if abs(deltaY) > 0.75 {
                let amount = String(
                    format: "%.2f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    deltaY * 2.6
                )
                dispatch("window.scrollBy(0,\(amount));", to: webView)
            }
            dispatch("window.__handarPointerMove(\(x),\(y),1);", to: webView)
        } else if !pinch && pointerDown {
            pointerDown = false
            dispatch("window.__handarPointerUp(\(x),\(y),1);", to: webView)
        } else {
            dispatch("window.__handarHover(\(x),\(y));", to: webView)
        }

        lastPoint = current
    }

    func release(webView: WKWebView) {
        guard pointerDown else {
            lastPoint = nil
            return
        }
        pointerDown = false
        dispatch("window.__handarPointerUp(window.innerWidth/2,window.innerHeight/2,1);", to: webView)
        lastPoint = nil
    }

    private func dispatch(_ script: String, to webView: WKWebView) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

// MARK: - РњРµРЅСЋ Рё РєР°Р»РёР±СЂРѕРІРєР° ----------------------------------------------------

final class MainMenuView: UIView {
    var onEnter: (() -> Void)?
    var onProfileChange: ((VRProfile) -> Void)?
    var onDiagnostics: (() -> Void)?
    var onSecurityGame: (() -> Void)?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let enterButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let passthroughSwitch = UISwitch()
    private var profile: VRProfile

    private let ipdRow = SliderRow(title: "РњРµР¶Р·СЂР°С‡РєРѕРІРѕРµ СЂР°СЃСЃС‚РѕСЏРЅРёРµ", unit: "РјРј", minimum: 52, maximum: 76, step: 0.5)
    private let lensRow = SliderRow(title: "Р Р°СЃСЃС‚РѕСЏРЅРёРµ РјРµР¶РґСѓ Р»РёРЅР·Р°РјРё", unit: "РјРј", minimum: 52, maximum: 76, step: 0.5)
    private let depthRow = SliderRow(title: "Р“Р»Р°Р· в†’ СЌРєСЂР°РЅ", unit: "РјРј", minimum: 30, maximum: 70, step: 0.5)
    private let k1Row = SliderRow(title: "Р”РёСЃС‚РѕСЂСЃРёСЏ k1", unit: "", minimum: 0, maximum: 0.8, step: 0.005)
    private let k2Row = SliderRow(title: "Р”РёСЃС‚РѕСЂСЃРёСЏ k2", unit: "", minimum: -0.2, maximum: 0.6, step: 0.005)

    init(frame: CGRect, profile: VRProfile) {
        self.profile = profile
        super.init(frame: frame)
        backgroundColor = .black
        build()
        applyProfile()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        titleLabel.text = "HandAR Vision"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 26, weight: .medium)
        titleLabel.textAlignment = .center

        subtitleLabel.text = "Р’СЃС‚Р°РІСЊ С‚РµР»РµС„РѕРЅ РІ С€Р»РµРј Рё РїРѕРґРіРѕРЅРё Р»РёРЅР·С‹ РїРѕРґ СЃРµР±СЏ"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textAlignment = .center

        var config = UIButton.Configuration.filled()
        config.title = "Р’РћР™РўР Р’ VR"
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.16, alpha: 1)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 34)
        enterButton.configuration = config
        enterButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        enterButton.addAction(UIAction { [weak self] _ in self?.onEnter?() }, for: .touchUpInside)

        let securityButton = UIButton(type: .system)
        securityButton.setTitle("🎮 VR ИГРА: SECURITY", for: .normal)
        securityButton.setTitleColor(.white, for: .normal)
        securityButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        securityButton.layer.cornerRadius = 18
        securityButton.backgroundColor = UIColor(red: 0.55, green: 0.12, blue: 0.62, alpha: 1)
        securityButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 18, bottom: 6, right: 18)
        securityButton.addAction(UIAction { [weak self] _ in self?.onSecurityGame?() }, for: .touchUpInside)

        let diagnosticsButton = UIButton(type: .system)
        diagnosticsButton.setTitle("РџР РћР’Р•Р РРўР¬ VR BOX 3.0", for: .normal)
        diagnosticsButton.setTitleColor(UIColor(white: 0.78, alpha: 1), for: .normal)
        diagnosticsButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        diagnosticsButton.addAction(UIAction { [weak self] _ in self?.onDiagnostics?() }, for: .touchUpInside)

        let passLabel = UILabel()
        passLabel.text = "РЎРєРІРѕР·РЅРѕРµ РІРёРґРµРѕ СЃ РєР°РјРµСЂС‹"
        passLabel.textColor = .white
        passLabel.font = .systemFont(ofSize: 13)
        passthroughSwitch.isOn = profile.passthrough
        passthroughSwitch.addAction(UIAction { [weak self] _ in self?.collect() }, for: .valueChanged)

        let passRow = UIStackView(arrangedSubviews: [passLabel, UIView(), passthroughSwitch])
        passRow.axis = .horizontal
        passRow.spacing = 12
        passRow.alignment = .center

        let resetButton = UIButton(type: .system)
        resetButton.setTitle("РЎР±СЂРѕСЃРёС‚СЊ РєР°Р»РёР±СЂРѕРІРєСѓ", for: .normal)
        resetButton.setTitleColor(UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1), for: .normal)
        resetButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
        resetButton.contentHorizontalAlignment = .leading
        resetButton.addAction(UIAction { [weak self] _ in self?.resetProfile() }, for: .touchUpInside)

        stack.axis = .vertical
        stack.spacing = 14
        for row in [ipdRow, lensRow, depthRow, k1Row, k2Row] {
            row.onChange = { [weak self] in self?.collect() }
            stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(passRow)
        stack.addArrangedSubview(resetButton)

        // РџСЏС‚СЊ РїРѕР»Р·СѓРЅРєРѕРІ РЅРµ РїРѕРјРµС‰Р°СЋС‚СЃСЏ РІ Р»Р°РЅРґС€Р°С„С‚ РїРѕ РІС‹СЃРѕС‚Рµ, РїРѕСЌС‚РѕРјСѓ
        // Р±Р»РѕРє РєР°Р»РёР±СЂРѕРІРєРё РїСЂРѕРєСЂСѓС‡РёРІР°РµС‚СЃСЏ, Р° РєРЅРѕРїРєР° РІС…РѕРґР° Р·Р°РєСЂРµРїР»РµРЅР° РІРЅРёР·Сѓ.
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.indicatorStyle = .white

        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        for subview in [titleLabel, subtitleLabel, securityButton, scrollView, enterButton, diagnosticsButton] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            securityButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            securityButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            securityButton.heightAnchor.constraint(equalToConstant: 36),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: securityButton.bottomAnchor, constant: 10),
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

    private func applyProfile() {
        ipdRow.value = profile.ipdMM
        lensRow.value = profile.lensSeparationMM
        depthRow.value = profile.eyeToScreenMM
        k1Row.value = profile.k1
        k2Row.value = profile.k2
        passthroughSwitch.isOn = profile.passthrough
    }

    private func collect() {
        profile.ipdMM = ipdRow.value
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

/// РџРѕРґРїРёСЃСЊ, Р·РЅР°С‡РµРЅРёРµ, РїРѕР»Р·СѓРЅРѕРє Рё РїР°СЂР° РєРЅРѕРїРѕРє С‚РѕС‡РЅРѕР№ РїРѕРґСЃС‚СЂРѕР№РєРё.
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

        // РџРѕР»Р·СѓРЅРєРѕРј РІ 40 С‚РѕС‡РµРє С€РёСЂРёРЅРѕР№ С‚РѕС‡РЅРѕРµ Р·РЅР°С‡РµРЅРёРµ РЅРµ РїРѕР№РјР°С‚СЊ,
        // РїРѕСЌС‚РѕРјСѓ СЂСЏРґРѕРј РєРЅРѕРїРєРё РЅР° РѕРґРёРЅ С€Р°Рі.
        configureStepButton(minusButton, title: "в€’", delta: -step)
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
            onMotionSample?(false, "РЅРµС‚ motion-РїСЂРѕС„РёР»СЏ")
            return
        }
        if motion.hasRotationRate {
            let r = motion.rotationRate
            let vector = SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z))
            onGyro?(vector)
            onMotionSample?(true, String(format: "gyro x=%+.2f  y=%+.2f  z=%+.2f rad/s", r.x, r.y, r.z))
        } else if motion.hasAttitude {
            onMotionSample?(false, "attitude РµСЃС‚СЊ, rotation rate РЅРµРґРѕСЃС‚СѓРїРµРЅ")
        } else if motion.hasGravityAndUserAcceleration {
            let a = motion.acceleration
            onMotionSample?(false, String(format: "accel x=%+.2f  y=%+.2f  z=%+.2f", a.x, a.y, a.z))
        } else {
            onMotionSample?(false, "motion-РїСЂРѕС„РёР»СЊ РµСЃС‚СЊ, РёР·РјРµСЂРµРЅРёСЏ РЅРµ РѕР±СЉСЏРІР»РµРЅС‹")
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
            onMotion?(motion.hasRotationRate, labels.joined(separator: ", ").isEmpty ? "motion: РїСЂРѕС„РёР»СЊ РµСЃС‚СЊ" : labels.joined(separator: ", "))
        }
    }

    private func publishStatus() {
        let found = controllers.first
        let name = found?.vendorName ?? found?.productCategory ?? "РќРµС‚ GameController"
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionChanged?(found != nil, name)
        }
    }
}

// MARK: - Р”РёР°РіРЅРѕСЃС‚РёРєР° VR BOX --------------------------------------------------

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
        title.text = "VR BOX 3.0 вЂў Р”РРђР“РќРћРЎРўРРљРђ"
        title.textColor = .white
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textAlignment = .center

        for label in [status, motion, input] {
            label.textColor = UIColor.white.withAlphaComponent(0.82)
            label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            label.numberOfLines = 3
        }

        input.text = "Stick/Button: Р¶РґС‘Рј СЃРѕР±С‹С‚РёСЏвЂ¦"

        log.textColor = UIColor(white: 0.78, alpha: 1)
        log.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        log.layer.cornerRadius = 18
        log.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        log.isEditable = false
        log.isSelectable = false

        let close = UIButton(type: .system)
        close.setTitle("Р—Р°РєСЂС‹С‚СЊ", for: .normal)
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
                self?.status.text = connected ? "Bluetooth/GameController: РџРћР”РљР›Р®Р§Р•Рќ\nРЈСЃС‚СЂРѕР№СЃС‚РІРѕ: \(name)" : "Bluetooth/GameController: РќР• Р’РР”РРў\nРЈСЃС‚СЂРѕР№СЃС‚РІРѕ: \(name)"
                self?.append("GameController: \(connected ? "connected" : "none") вЂ” \(name)")
            }
        }
        service.onMotion = { [weak self] hasGyro, detail in
            DispatchQueue.main.async {
                self?.motion.text = "Motion: \(hasGyro ? "GYRO Р•РЎРўР¬" : "GYRO РќР• РћР‘РќРђР РЈР–Р•Рќ")\n\(detail)"
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
        status.text = "РС‰РµРј РєРѕРЅС‚СЂРѕР»Р»РµСЂС‹ iOSвЂ¦"
        motion.text = "Motion: Р¶РґС‘Рј РґР°РЅРЅС‹РµвЂ¦"
        input.text = "Stick/Button: Р¶РґС‘Рј СЃРѕР±С‹С‚РёСЏвЂ¦"
        log.text = "РџРѕС€РµРІРµР»Рё РґР¶РѕР№СЃС‚РёРє Рё РЅР°Р¶РјРё РєР°Р¶РґСѓСЋ РєРЅРѕРїРєСѓ.\n\n"
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
