//
//  VRHallEngine.swift
//  HandARCinema
//
//  Общий движок VR-гарнитуры: профиль линз, математика фрустума,
//  стереокомпозитор Metal, трекинг рук Vision и поза головы ARKit.
//  Код перенесён из HandAR Browser и не зависит от браузера.
//

import ARKit
import ImageIO
import Metal
import MetalKit
import QuartzCore
import SceneKit
import simd
import UIKit
import Vision
struct HandSample {
    let indexTip: CGPoint
    let middleTip: CGPoint
    let thumbTip: CGPoint
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    /// Средний + большой: нажатие.
    let clickPinch: Bool
    /// Указательный + большой: захват панели.
    let grabPinch: Bool
    /// Рука в кулаке — пальцы согнуты.
    let isFist: Bool
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

    /// Межзрачковое расстояние пользователя.
    var ipdMM: Float = 63
    /// Расстояние между центрами линз шлема.
    var lensSeparationMM: Float = 63
    /// Смещение центров линз по вертикали относительно центра экрана.
    var lensVerticalOffsetMM: Float = 0
    /// Расстояние от глаза до экрана сквозь линзу.
    var eyeToScreenMM: Float = 42

    /// Коэффициенты радиального предыскажения.
    var k1: Float = 0.0
    var k2: Float = 0.0
    /// Без искусственной хроматики: картинка заполняет весь экран.
    var chroma: Float = 0.0
    /// Сохраняется для совместимости профиля; фактический радиус круглой
    /// линзы вычисляется автоматически по размеру экрана.
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

/// Границы пирамиды видимости на единичном расстоянии (тангенсы углов).
struct EyeFrustum {
    var left: Float
    var right: Float
    var bottom: Float
    var top: Float
}

enum VRLensMath {
    /// Симметричный фрустум: левый и правый глаз получают одинаковую
    /// ширину и одинаковый горизонтальный FOV. Межзрачковое расстояние
    /// используется только для разнесения камер, а не для сдвига картинки
    /// внутри своей половины экрана. Это устраняет неравномерное сведение
    /// двух изображений под физические линзы шлема.
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

        // Рендерим шире видимого: предыскажение утягивает края к центру.
        let scale = max(profile.fovScale, 1)
        let centerX = (frustum.left + frustum.right) * 0.5
        let centerY = (frustum.bottom + frustum.top) * 0.5
        frustum.left = centerX + (frustum.left - centerX) * scale
        frustum.right = centerX + (frustum.right - centerX) * scale
        frustum.bottom = centerY + (frustum.bottom - centerY) * scale
        frustum.top = centerY + (frustum.top - centerY) * scale
        return frustum
    }

    /// Центр каждой линзы всегда находится в центре своей половины дисплея.
    /// Поэтому левое и правое изображения имеют одинаковую геометрию и
    /// не расходятся по горизонтали.
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

// MARK: - Metal-композитор -----------------------------------------------------

struct VRUniforms {
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

        // Изотропное пространство линзы.
        float2 p = (eyeUV - center) * float2(u.aspect, 1.0);
        float r2 = dot(p, p);
        float r = sqrt(r2);
        if (u.rClip < 5.0 && r > u.rClip) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        // Предыскажение: берём источник дальше от центра, чтобы линза,
        // растягивающая картинку наружу, вернула прямые линии прямыми.
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

        // Реальный передний план руки: маска задаётся Vision, цвет берётся
        // непосредственно из текущего кадра камеры, поэтому рука находится
        // поверх виртуального браузера без нарисованного скелета.
        if (u.handMaskEnabled > 0.5 && validCamUV) {
            float handAlpha = handMask.sample(smp, camUV).r;
            if (handAlpha > 0.01) {
                float yyHand = camY.sample(smp, camUV).r;
                float2 ccHand = camCbCr.sample(smp, camUV).rg;
                float3 handColor = clamp(ycbcr_to_rgb(yyHand, ccHand), 0.0, 1.0);
                color = mix(color, handColor, handAlpha);
            }
        }

        // Мягкий край именно круглой линзы: внутри круга 100%, на
        // последних ~0.008 единицы плавно уходим в чёрный.
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

    func encode(
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

    /// Матрица головы в мире с поправкой на ориентацию интерфейса.
    func headTransform(_ frame: ARFrame) -> simd_float4x4 {
        frame.camera.viewMatrix(for: interfaceOrientation).inverse
    }

    /// Луч из точки, найденной Vision, в мировые координаты.
    /// Считаем через интринсики камеры: никакого согласования вьюпортов.
    func worldRay(visionPoint: CGPoint) -> WorldRay? {
        guard let frame = latestFrameCopy else { return nil }

        let resolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]
        guard fx > 0, fy > 0 else { return nil }

        // Vision отдаёт нормированные координаты ориентированного кадра
        // (начало — левый низ). Возвращаемся в координаты сырого кадра.
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
            onFailure?("Этот iPhone не поддерживает ARKit World Tracking.")
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isAutoFocusEnabled = true
        configuration.planeDetection = []
        configuration.environmentTexturing = ARWorldTrackingConfiguration.EnvironmentTexturing.none

        // Реконструкция сцены и текстурирование окружения стоят кадров,
        // а в стереорежиме бюджет кадра важнее.
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
        onFailure?("ARKit завершил сессию: \(error.localizedDescription)")
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
        if let latest = VNDetectHumanHandPoseRequest.supportedRevisions.max() {
            request.revision = latest
        }
        return request
    }()

    private let queue = DispatchQueue(label: "handar.vision", qos: .userInitiated)
    private let gate = DispatchSemaphore(value: 1)

    /// Сглаженные позиции и состояния щипков по каждой руке.
    private struct HandState {
        var index: CGPoint?
        var middle: CGPoint?
        var thumb: CGPoint?
        var joints: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
        /// Сколько кадров подряд сустав не распознаётся — пока лимит не вышел,
        /// виртуальный сустав держит последнюю стабильную позицию.
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

                    // Пропавшие суставы (палец за пальцем, в тени) не телепортируют
                    // виртуальную руку — держим последнюю стабильную позицию
                    // до лимита кадров, иначе скрываем узел.
                    for (jointName, old) in state.joints {
                        guard filteredJoints[jointName] == nil else { continue }
                        let age = (state.jointAges[jointName] ?? 0) + 1
                        state.jointAges[jointName] = age
                        if age <= 18 {
                            filteredJoints[jointName] = old
                        }
                    }

                    // Кулак: считаем согнутые пальцы по углу в PIP.
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

                    // Нормируем на ладонь, но не требуем идеального распознавания
                    // среднего пальца каждый кадр. Так курсор остаётся стабильным,
                    // а средний+большой используется только как команда клика.
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
