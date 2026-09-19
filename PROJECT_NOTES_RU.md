# V29 notes

Переход от split-screen к настоящему стереоконвейеру.

## Удалено

- `ARSCNView` как полноэкранная подложка с видео.
- `leftEyeView` / `rightEyeView` (`SCNView`).
- `leftScene` / `rightScene`, `leftPlaneNode` / `rightPlaneNode`,
  `leftMaterial` / `rightMaterial`, `leftCursorNode` / `rightCursorNode`.
- `frame.camera.projectionMatrix(...)` в роли проекции глаза.
- `eyeSeparation: Float = 0.064` как единственная «стереонастройка».

## Добавлено

- `VRProfile` — параметры шлема в миллиметрах, сохраняются в `UserDefaults`.
- `EyeFrustum` + `VRLensMath` — асимметричные фрустумы и центры линз.
- `VRCompositor` — Metal-пайплайн, собирается в рантайме из строки с исходником.
- `MTKView` + `MTKViewDelegate` вместо двух `SCNView`.
- Два `SCNRenderer` поверх одной `SCNScene`, рендер в общую офскрин-текстуру.
- `headNode` с двумя дочерними камерами на `±ipd/2`.
- `CVMetalTextureCache` + YCbCr→RGB в шейдере для пер-глазного passthrough.
- Экран калибровки линз в главном меню (`SliderRow`).

## Сохранено из V28

- `HandTracker` целиком: хиральность, сглаживание с адаптивной альфой,
  нормировка щипка на размер ладони, гистерезис.
- `WebInputBridge` целиком, включая прокрутку зажатым щипком.
- `ARAnchor` как источник правды для положения панели.
- Жест «щипок обеими руками» = поставить панель заново.
- Landscape-only, размеры панели 0.82 × 0.47 м на 1.55 м.

## Важные детали реализации

- `ARCamera.unprojectPoint(_:ontoPlane:)` кладёт луч на локальную плоскость **XZ**,
  где нормаль — локальная Y. Панель лежит в XY, поэтому оси переставляются в
  `browserPlaneForUnprojection`.
- Луч пальца считается прямо в координатах кадра камеры
  (`viewportSize: frame.camera.imageResolution`), а не в координатах половины
  экрана. В V28 точка бралась по полному вьюпорту, а распроецировалась по
  половинному — несогласованность, дававшая смещение курсора.
- Глаза рендерятся с прозрачным фоном (`clearColor` с alpha 0), фон
  подкладывает композитор. Это позволяет дать каждому глазу собственную
  выборку из кадра камеры.
- `CVMetalTexture` удерживается до `addCompletedHandler`, иначе текстура
  освобождается посреди кадра.
- `project.pbxproj`: в `OTHER_LDFLAGS` добавлены `-framework Metal` и
  `-framework MetalKit`.
- `Scripts/CHECK_PROJECT.command` переписан под новые инварианты; старые проверки
  (`arSceneView`, `leftEyeView`, `eyeSeparation: Float = 0.064`) уронили бы CI.
