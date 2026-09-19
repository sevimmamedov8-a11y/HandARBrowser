# V26 notes

V26 заменяет прошлый вариант с одним разделённым визуальным слоем на две независимые области рендеринга.

- Left eye: отдельный `WKWebView`.
- Right eye: отдельный `WKWebView`.
- Один `ARAnchor` фиксирует мировую позицию виртуального окна.
- `AnchorEntity(anchor:)` подключает тот же anchor к RealityKit-сцене.
- `ARSessionDelegate.didUpdateAnchors` получает уточнённое положение anchor от ARKit.
- Каждый глаз проецируется отдельно с небольшим `eyeSeparation`.
- Круглые линзы/маски и stacked portrait layout удалены.
- LandscapeLeft и LandscapeRight разрешены, чтобы экран очков всегда оставался горизонтальным.

V29: добавлены полный hand skeleton поверх AR, навигационные жесты назад/вперёд, более устойчивый scroll/drag через WebInput.js и подсказка по управлению.
