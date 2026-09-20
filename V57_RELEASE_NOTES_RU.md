# HandARBrowser V57 — YouTube video picture path

Исправлен именно VR-путь видео, а не только стили.

- YouTube watch/shorts/live URL преобразуется в dedicated embed URL.
- Direct video WKWebView больше не получает WebInput.js целиком и не патчит Fullscreen API.
- Добавлен минимальный pointer bridge для управления видео рукой/контроллером.
- Убран deprecated processPool из direct video configuration.
- Inline playback, AirPlay и PiP настроены явно.
- Левая линза со звуком, правая без звука.
- Круглая VR-маска остаётся отдельным sibling overlay, не маскирующим WKWebView.
- Build number: 57.

Ограничение: физическое воспроизведение на iPhone в этом окружении не выполнялось.
