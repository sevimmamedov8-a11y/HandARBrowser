# V25 technology notes

Основные системные компоненты:

- ARKit — world tracking, ARSession, ARAnchor и camera frames.
- RealityKit — `ARView` для AR passthrough и `AnchorEntity` для связи виртуального объекта с ARAnchor.
- Vision — human hand pose tracking.
- WebKit — два независимых WKWebView, по одному на каждый eye view.

Архитектура V25 ориентирована на идею пространственных окон: виртуальный браузер имеет мировую позицию и не должен следовать за поворотом телефона как обычный HUD.
