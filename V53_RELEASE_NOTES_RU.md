# V53 — YouTube video rendering/audio fix

Исправлено чёрное видео в YouTube при VR-композитинге. WKWebView takeSnapshot не захватывает аппаратно декодируемый HTML5 video, поэтому субтитры попадали в snapshot, а сам видеокадр оставался чёрным. В V53 для YouTube/TikTok кинорежим использует два видимых WKWebView, по одному на каждую линзу. Левый глаз даёт звук, правый синхронизируется и отключён по звуку.

Добавлена активация AVAudioSession для media playback, повторная настройка playsInline/muted/volume, синхронизация currentTime/playbackRate/paused и отдельный pointer для управления рукой/VR BOX.

Полная сборка на iPhone физически здесь не выполнялась.
