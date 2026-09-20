# V29 / V30 notes

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

## V30

Добавлено:

- `WorldRay` + `ARStereoTrackingManager.worldRay(visionPoint:)` — луч из
  интринсик камеры, без согласования вьюпортов.
- `planeHit(ray:transform:)` — аналитическое пересечение с плоскостью панели,
  сразу отдаёт локальные X/Y. `browserPlaneForUnprojection` удалён.
- `rayNode` (цилиндр, растягивается по длине каждый кадр) и `pointerNode`
  (диск + тор). Локальная ось Y обеих геометрий кладётся на нормаль панели,
  иначе точка встаёт ребром.
- Разделение жестов: `clickPinch` (средний + большой) и `grabPinch`
  (указательный + большой). `HandTracker` хранит состояние в `HandState`
  по каждой руке, гистерезис отдельный для каждого щипка.
- Перетаскивание панели: `updateDrag(with:)` + `endDrag()`. Смещение
  запоминается в момент захвата, поэтому панель не прыгает к пальцу.
  `ARAnchor` неизменяем, поэтому на отпускании старый снимается и ставится
  новый (`commitAnchor`).
- `ToolbarItem` и планка кнопок над браузером: Google, YouTube, TikTok, Назад.
  Текстуры рисуются через `UIGraphicsImageRenderer`, подсветка перерисовывает
  их только при смене наведённой кнопки.
- Меню: калибровка уехала в `UIScrollView` (пять ползунков не влезали в
  ландшафт), у каждого ползунка появились кнопки шага и точный вывод значения,
  добавлен сброс калибровки.

Защита от регрессий: `onAnchorUpdate` игнорирует обновления во время
перетаскивания, иначе ARKit возвращал бы панель на старое место каждый кадр.

## V30.1 — фикс сборки

CI падал на `error: overriding property must be as accessible as its enclosing
type` / `property 'toolbarItems' ... cannot override a property with type
'[UIBarButtonItem]?'`. Причина: `UIViewController` уже объявляет
`var toolbarItems: [UIBarButtonItem]?` (через категорию, см. `UINavigationController.h`),
и одноимённое приватное свойство `[ToolbarItem]` в `MainViewController`
компилятор трактует как несовместимое переопределение.

Переименовал `toolbarItems` → `linkItems` везде (объявление и все обращения).
Остальные имена свойств панели ссылок (`toolbarNode`, `toolbarButtonNodes`,
`toolbarCenterY`, `toolbarButtonHeight`, `highlightedToolbarIndex`) не
конфликтуют — в UIKit таких свойств у `UIViewController` нет.

`Scripts/CHECK_PROJECT.command` теперь проверяет и наличие `linkItems`,
и отсутствие `private var toolbarItems`, чтобы регрессия не прошла тихо.

## V31

Запрос: панель в шлеме выглядит как маленький квадрат, а не как полноэкранное
изображение; видео на YouTube/TikTok должно раскрываться отдельно.

Добавлено:

- `MainViewController.defaultPanelWidth/Height` (1.60 × 1.00 м) заменили
  старые 0.82 × 0.47 м — панель физически больше, занимает заметно больше
  поля зрения. `browserWorldDistance` чуть отодвинут (1.55 → 1.65 м), чтобы
  увеличенная панель не давила по краям при близком просмотре.
- `browserWorldWidth`/`browserWorldHeight` стали `var` (были `let`) —
  необходимо для смены размера между обычным и кинорежимом.
- `browserPlaneGeometry`, `browserFrameGeometry`, `browserHandleNode` —
  сохранённые ссылки на геометрию панели, рамки и ручки, чтобы их можно было
  менять на лету. Меняется именно геометрия (`SCNPlane.width/height`), а не
  `SCNNode.scale` — потому что `applyBrowserWorldTransform()` регулярно
  перезаписывает `simdWorldTransform` узла панели (например, при обновлении
  ARKit-якоря), и это стёрло бы отдельно выставленный `.scale`. Изменение
  самой геометрии не зависит от transform и не подвержено этой гонке.
- `setCinemaMode(_:)` — переключение между обычным (1.60×1.00) и
  кинорежимом (2.85×1.62), с анимацией через `SCNTransaction`
  (`SCNPlane.width/height` анимируемы). Планка ссылок прячется на время
  кинорежима (`toolbarNode.isHidden`), её собственная разметка не
  пересчитывается — она всегда строится по размеру обычного режима.
- `resetPanelToDefaultSizeInstantly()` — обычный размер восстанавливается
  без анимации при каждом входе в VR (`enterVR()`), пока панель ещё скрыта.
- `WKScriptMessageHandler` (`handarVideo`) — `WebInput.js` определяет, что
  видео доминирует на странице (Fullscreen API, `webkitbeginfullscreen` для
  инлайн-видео WebKit, либо доля видимой площади для ленты TikTok, где
  отдельной кнопки fullscreen обычно нет), и шлёт `{active: bool}`.
  Обработчик регистрируется в `configureBrowser()` (там уже есть `self`;
  в статическом инициализаторе `browser` его ещё нет) и снимается в
  `deinit`, чтобы не оставлять цикл сильных ссылок через
  `WKUserContentController`.
- Частота `startBrowserCapture()` зависит от `isCinemaMode`: 12 fps на
  обычной странице, 24 fps на видео. Разрешение `takeSnapshot` — 1024 px
  обычно, 1536 px в кинорежиме (панель почти вдвое шире, тот же снимок
  размылился бы).
- `planeHit`-логика в `handleHands` игнорирует зону планки ссылок, пока
  `isCinemaMode == true` — иначе палец мог бы «щёлкать» по невидимой планке.
- `VRProfile.fovScale`: 1.18 → 1.25 — плотнее заполняет круглую область
  линзы, меньше чёрных полей по краю обзора.

`Scripts/CHECK_PROJECT.command` дополнен инвариантами на кинорежим и на
новый размер панели по умолчанию.


V37: вместо видимого скелета поверх браузера композятся настоящие пиксели рук из камеры по маске Vision.


### V39 — исправление неравномерного сведения глаз
- `VRLensMath.frustum` переведён на симметричный FOV для обеих половин дисплея.
- `lensCenterUV` закреплён на `0.5` по горизонтали для обоих глаз.
- `ipdMM` теперь влияет только на физическое разнесение камер.
- Обновлён `CFBundleVersion` до 38 и `CHECK_PROJECT.command` до V39.
