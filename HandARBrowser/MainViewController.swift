//
//  MainViewController.swift
//  HandAR Vision — V40
//
//  Стереоконвейер
//  Передний план: реальные пиксели рук из камеры композятся поверх браузера по маске Vision.
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
//    • Нажатие: СРЕДНИЙ + большой палец.
//    • Перетаскивание панели: УКАЗАТЕЛЬНЫЙ + большой, рука в нижней трети кадра.
//    • Масштаб: две руки, средний + большой на каждой; двигаем указательные
//      дальше друг от друга — окно увеличивается, ближе — уменьшается.
//    • Панель ссылок над браузером: Google, YouTube, TikTok, Назад.
//

import UIKit
import AVFoundation
import ARKit
import SceneKit
import Vision
import WebKit
import Metal
import MetalKit
import simd

struct HandSample {
    let indexTip: CGPoint
    let middleTip: CGPoint
    let thumbTip: CGPoint
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    /// Средний + большой: нажатие.
    let clickPinch: Bool
    /// Указательный + большой: захват панели.
    let grabPinch: Bool
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
    }

    let title: String
    let action: Action
    /// Границы по локальной оси X панели, в метрах от её центра.
    var minX: Float = 0
    var maxX: Float = 0
}

// MARK: - Главный контроллер ---------------------------------------------------

final class MainViewController: UIViewController, MTKViewDelegate {
    private let tracking = ARStereoTrackingManager()
    private let hands = HandTracker()
    private let input = WebInputBridge()

    // Одна логическая поверхность браузера. Стерео рождается из двух камер,
    // а не из двух копий страницы.
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
    private let handMaskWidth = 320
    private let handMaskHeight = 320
    private var handMaskTexture: MTLTexture?
    private let handMaskLock = NSLock()
    private var pendingHandMaskBytes = [UInt8]()
    private var pendingHandMaskActive = false

    // Сцена: одна на оба глаза
    private let worldScene = SCNScene()
    private var leftRenderer: SCNRenderer!
    private var rightRenderer: SCNRenderer!
    private let headNode = SCNNode()
    private let leftCameraNode = SCNNode()
    private let rightCameraNode = SCNNode()
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
    private var leftSkeletonJoints: [VNHumanHandPoseObservation.JointName: SCNNode] = [:]
    private var rightSkeletonJoints: [VNHumanHandPoseObservation.JointName: SCNNode] = [:]
    private var leftSkeletonBones: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, SCNNode)] = []
    private var rightSkeletonBones: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, SCNNode)] = []

    // Планка ссылок над браузером.
    private let toolbarNode = SCNNode()
    private var linkItems: [ToolbarItem] = []
    private var toolbarButtonNodes: [SCNNode] = []
    private var toolbarCenterY: Float = 0
    private let toolbarButtonHeight: Float = 0.072
    private var highlightedToolbarIndex: Int?

    private var menu: MainMenuView!

    private var profile = VRProfile.load()
    private var inVR = false
    private var browserAnchor: ARAnchor?
    private var browserWorldTransform: simd_float4x4?
    private var didCreateInitialAnchor = false

    // Перетаскивание панели
    private var isDragging = false
    private var dragDistance: Float = 1.55
    private var dragOffset = SIMD3<Float>(repeating: 0)
    private var wasClickPinching = false

    // Масштабирование двумя руками: обе руки делают средний+большой палец,
    // затем расстояние между кончиками указательных меняет размер панели.
    private var isResizing = false
    private var resizeStartHandDistance: CGFloat = 0
    private var resizeStartWidth: Float = MainViewController.defaultPanelWidth

    // Панель браузера в мире. Размер большой намеренно: панель размером
    // с почтовый конверт на расстоянии вытянутой руки занимает жалкую часть
    // поля зрения и выглядит как маленький квадрат посреди черноты. Здесь
    // панель по умолчанию — это уже «большой монитор», а не окошко.
    private static let defaultPanelWidth: Float = 2.70
    private static let defaultPanelHeight: Float = 1.52
    private static let minimumPanelWidth: Float = 0.72
    private static let maximumPanelWidth: Float = 3.80
    private static let defaultPanelAspect: Float = defaultPanelHeight / defaultPanelWidth
    /// Видео на YouTube/TikTok разворачивается в «кинозал»: экран занимает
    /// большую часть поля зрения шлема, почти как в настоящем VR-кинотеатре.
    private static let cinemaPanelWidth: Float = 2.85
    private static let cinemaPanelHeight: Float = 1.62
    private var browserWorldWidth: Float = MainViewController.defaultPanelWidth
    private var browserWorldHeight: Float = MainViewController.defaultPanelHeight
    private let browserWorldDistance: Float = 1.65
    private var isCinemaMode = false
    private var browserPlaneGeometry: SCNPlane!
    private var browserFrameGeometry: SCNBox!
    private var browserHandleNode: SCNNode!
    /// Ниже этой доли кадра щипок указательным считается захватом панели.
    private let dragZoneHeight: CGFloat = 0.34
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

    // MARK: Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureMetal()
        configureScene()
        configureBrowser()
        buildInterface()
        wireServices()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestLandscapeMode()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutViews()
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
        // WKUserContentController держит обработчик сильной ссылкой —
        // без явного снятия получился бы цикл ретейнов.
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "handarVideo")
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
        rightRenderer = SCNRenderer(device: metalDevice, options: nil)
        for renderer in [leftRenderer, rightRenderer] {
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
        let frameNode = SCNNode(geometry: frameGeometry)
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

    /// Переключает браузер между обычным VR-экраном и большим VR-экраном
    /// для видео. Это всё ещё та же мировая стерео-панель: меняется только
    /// её размер, поэтому YouTube остаётся внутри VR-композитора.
    private func setCinemaMode(_ active: Bool) {
        guard active != isCinemaMode else { return }
        isCinemaMode = active

        let width = active ? Self.cinemaPanelWidth : Self.defaultPanelWidth
        let height = width * Self.defaultPanelAspect
        browserWorldWidth = width
        browserWorldHeight = height

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.32
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        browserPlaneGeometry.width = CGFloat(width)
        browserPlaneGeometry.height = CGFloat(height)
        browserFrameGeometry.width = CGFloat(width) + 0.018
        browserFrameGeometry.height = CGFloat(height) + 0.018
        browserHandleNode.position = SCNVector3(0, -Double(height) * 0.5 - 0.028, 0)
        toolbarNode.opacity = active ? 0 : 1
        SCNTransaction.commit()

        toolbarNode.isHidden = active
        startBrowserCapture()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func buildToolbar() {
        var items: [ToolbarItem] = [
            ToolbarItem(title: "Google", action: .open(Self.homeURL)),
            ToolbarItem(title: "YouTube", action: .open(Self.youTubeURL)),
            ToolbarItem(title: "TikTok", action: .open(Self.tikTokURL)),
            ToolbarItem(title: "Назад", action: .back)
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

    /// Текстура кнопки. Рисуем заранее — в VR нет места для UIKit-слоёв.
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
        buildSingleHandSkeleton(root: leftHandSkeletonNode, joints: &leftSkeletonJoints, bones: &leftSkeletonBones, color: UIColor(red: 0.35, green: 0.90, blue: 1.0, alpha: 1))
        buildSingleHandSkeleton(root: rightHandSkeletonNode, joints: &rightSkeletonJoints, bones: &rightSkeletonBones, color: UIColor(red: 1.0, green: 0.58, blue: 0.32, alpha: 1))
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
        color: UIColor
    ) {
        let jointMaterial = SCNMaterial()
        jointMaterial.lightingModel = .constant
        jointMaterial.diffuse.contents = color
        jointMaterial.emission.contents = color
        jointMaterial.readsFromDepthBuffer = false
        jointMaterial.writesToDepthBuffer = false

        let boneMaterial = jointMaterial.copy() as! SCNMaterial

        let jointNames: [VNHumanHandPoseObservation.JointName] = [
            .wrist,
            .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
            .indexMCP, .indexPIP, .indexDIP, .indexTip,
            .middleMCP, .middlePIP, .middleDIP, .middleTip,
            .ringMCP, .ringPIP, .ringDIP, .ringTip,
            .littleMCP, .littlePIP, .littleDIP, .littleTip
        ]

        for jointName in jointNames {
            let sphere = SCNSphere(radius: 0.011)
            sphere.segmentCount = 10
            sphere.firstMaterial = jointMaterial.copy() as? SCNMaterial
            let node = SCNNode(geometry: sphere)
            node.renderingOrder = 221
            node.isHidden = true
            root.addChildNode(node)
            joints[jointName] = node
        }

        for (a, b) in Self.handSkeletonBonePairs {
            let cylinder = SCNCylinder(radius: 0.0042, height: 1.0)
            cylinder.radialSegmentCount = 8
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
    private func applyEyeGeometry() {
        let halfIPD = profile.ipdMM * 0.0005   // мм → м и пополам
        leftCameraNode.simdPosition = SIMD3<Float>(-halfIPD, 0, 0)
        rightCameraNode.simdPosition = SIMD3<Float>(halfIPD, 0, 0)

        let near: Float = 0.02
        let far: Float = 100
        let left = VRLensMath.frustum(eye: 0, profile: profile)
        let right = VRLensMath.frustum(eye: 1, profile: profile)
        leftCameraNode.camera?.projectionTransform = VRLensMath.projection(left, near: near, far: far)
        rightCameraNode.camera?.projectionTransform = VRLensMath.projection(right, near: near, far: far)
    }

    private func configureBrowser() {
        browser.navigationDelegate = self
        browser.uiDelegate = self
        // WebInput.js следит за плеером страницы и шлёт сюда true/false,
        // когда видео на YouTube/TikTok разворачивается на весь экран —
        // это и включает кинорежим.
        browser.configuration.userContentController.add(self, name: "handarVideo")
        browser.load(URLRequest(url: Self.homeURL))
    }

    private func buildInterface() {
        // Браузер живёт под VR-выводом: ему нужен настоящий размер и окно,
        // иначе takeSnapshot отдаёт пустоту.
        view.addSubview(browser)
        if vrView != nil {
            view.addSubview(vrView)
        }

        menu = MainMenuView(frame: view.bounds, profile: profile)
        menu.onEnter = { [weak self] in
            self?.requestCameraAndEnterVR()
        }
        menu.onProfileChange = { [weak self] updated in
            guard let self else { return }
            self.profile = updated
            self.applyEyeGeometry()
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

        hands.onUpdate = { [weak self] left, right in
            DispatchQueue.main.async {
                self?.handleHands(left: left, right: right)
            }
        }
    }

    // MARK: Вход и выход

    private func requestCameraAndEnterVR() {
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
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if allowed {
                        self.enterVR()
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
        resetPanelToDefaultSizeInstantly()

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

    private func leaveVRToMenu() {
        tracking.pause()
        stopBrowserCapture()
        releasePointer()

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
        setVRVisible(false)
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
        // Чтение страницы сносно смотрится на 12 fps. Видео на 12 fps
        // дёргается заметно, поэтому в кинорежиме поднимаем частоту.
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
        guard inVR, !snapshotInProgress else { return }
        guard browser.bounds.width > 1, browser.bounds.height > 1 else { return }
        snapshotInProgress = true

        let configuration = WKSnapshotConfiguration()
        // Кинопанель почти вдвое шире обычной — тот же снимок на ней
        // размылился бы, поэтому берём его крупнее.
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

    // MARK: Руки и указатель

    private func handleHands(left: HandSample?, right: HandSample?) {
        guard inVR else { return }
        queueHandForegroundMask(left: left, right: right)

        // Две руки: средний+большой палец = режим изменения размера.
        // Расходятся указательные — окно увеличивается, сходятся — уменьшается.
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
            return
        }

        // Захват: указательный + большой, рука в нижней трети кадра.
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

        // Планка ссылок над браузером. Во время видео она скрыта —
        // пропускаем и зону попадания, иначе палец «щёлкал» бы по невидимке.
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
        }
    }

    /// Пересечение луча с плоскостью панели. Считаем напрямую: это дешевле
    /// и честнее, чем гонять точку через вьюпорты.
    /// Скелет кладём прямо на мировую плоскость браузера и сдвигаем на 18 мм
    /// к камере. Поэтому при движении браузера скелет остаётся совмещённым
    /// с рукой, но не проваливается под текстуру страницы.
    private static let handMaskBonePairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip)
    ]

    /// Создаёт маску кисти в координатах сырого кадра камеры. В ней нет
    /// графики скелета — она только определяет, какие настоящие пиксели камеры
    /// нужно показать поверх браузера.
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

        // Vision/камера используют верхний левый угол как начало UV в нашей схеме.
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
        updateSingleHandSkeleton(sample: left, root: leftHandSkeletonNode, joints: leftSkeletonJoints, bones: leftSkeletonBones)
        updateSingleHandSkeleton(sample: right, root: rightHandSkeletonNode, joints: rightSkeletonJoints, bones: rightSkeletonBones)
    }

    private func updateSingleHandSkeleton(
        sample: HandSample?,
        root: SCNNode,
        joints: [VNHumanHandPoseObservation.JointName: SCNNode],
        bones: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, SCNNode)]
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

        // Проход 2 — правый глаз в ту же текстуру.
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

        // Проход 3 — оптика линз плюс сквозное видео.
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
        // Круглая линза максимально заполняет свою половину дисплея.
        // Радиус ограничен и по высоте, и по ширине, поэтому окружность
        // не превращается в овал и одинакова для обоих глаз.
        let maxLensRadius = min(0.5, 0.5 / max(uniforms.aspect, 0.001))
        uniforms.rClip = maxLensRadius * 0.985
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

        // Половина поля зрения реальной камеры в тангенсах.
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

    /// Линейное отображение координат глаза в координаты кадра камеры так,
    /// чтобы угловые размеры совпали: пиксель под углом X в глазу берётся
    /// из пикселя под тем же углом X в камере.
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
            // В landscapeLeft кадр камеры повёрнут на 180°.
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

        // CVMetalTexture должен дожить до конца кадра.
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
        guard
            message.name == "handarVideo",
            let body = message.body as? [String: Any],
            let active = body["active"] as? Bool
        else {
            return
        }
        setCinemaMode(active)
    }
}

extension MainViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateBrowserSnapshot()
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
        var clickPinch = false
        var grabPinch = false

        mutating func reset() {
            index = nil
            middle = nil
            thumb = nil
            joints.removeAll(keepingCapacity: true)
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
                        grabPinch: state.grabPinch
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

// MARK: - Ввод в страницу ------------------------------------------------------

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

// MARK: - Меню и калибровка ----------------------------------------------------

final class MainMenuView: UIView {
    var onEnter: (() -> Void)?
    var onProfileChange: ((VRProfile) -> Void)?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let enterButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let passthroughSwitch = UISwitch()
    private var profile: VRProfile

    private let ipdRow = SliderRow(title: "Межзрачковое расстояние", unit: "мм", minimum: 52, maximum: 76, step: 0.5)
    private let lensRow = SliderRow(title: "Расстояние между линзами", unit: "мм", minimum: 52, maximum: 76, step: 0.5)
    private let depthRow = SliderRow(title: "Глаз → экран", unit: "мм", minimum: 30, maximum: 70, step: 0.5)
    private let k1Row = SliderRow(title: "Дисторсия k1", unit: "", minimum: 0, maximum: 0.8, step: 0.005)
    private let k2Row = SliderRow(title: "Дисторсия k2", unit: "", minimum: -0.2, maximum: 0.6, step: 0.005)

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

        subtitleLabel.text = "Вставь телефон в шлем и подгони линзы под себя"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textAlignment = .center

        var config = UIButton.Configuration.filled()
        config.title = "ВОЙТИ В VR"
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.16, alpha: 1)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 34, bottom: 0, trailing: 34)
        enterButton.configuration = config
        enterButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        enterButton.addAction(UIAction { [weak self] _ in self?.onEnter?() }, for: .touchUpInside)

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
        for row in [ipdRow, lensRow, depthRow, k1Row, k2Row] {
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

        for subview in [titleLabel, subtitleLabel, scrollView, enterButton] as [UIView] {
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

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
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
            enterButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10)
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
