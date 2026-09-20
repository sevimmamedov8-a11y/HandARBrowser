# HandARBrowser V55

## Исправление чёрного YouTube-видео

V54 уже перенёс видео из snapshot в реальные WKWebView, но на устройстве был звук без картинки. V55 убирает округлую маску непосредственно с WKWebView-слоёв: круглые линзы теперь рисуются отдельным прозрачным overlay с чёрной областью снаружи. Для hardware-decoded HTML5 video веб-представления остаются прямоугольными. Также добавлены принудительные display/visibility/opacity/object-fit/translateZ(0) для video element.

Это не устраняет ограничения WebKit для takeSnapshot: аппаратное HTML5-видео по-прежнему не захватывается snapshot-API, поэтому direct-video stage остаётся отдельным.
