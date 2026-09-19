# Сборка IPA через GitHub без Mac

Этот проект специально подготовлен под сборку на `macos-latest` в GitHub Actions.
На Windows ничего компилировать не нужно.

## Что загрузить в репозиторий

Загрузи **весь контент этой папки** в корень репозитория `HandARBrowser`.
То есть структура должна начинаться так:

```text
HandARBrowser.xcodeproj/
HandARBrowser/
Scripts/
.github/
README_RU.md
...
```

Не делай:

```text
HandARBrowser/HandARBrowser.xcodeproj/
```

## Как получить IPA

После commit/push workflow `Build HandARBrowser IPA` запускается автоматически.
Его также можно запустить вручную из `Actions`.

Успешный запуск создаёт artifact:

```text
HandARBrowser-IPA
└── HandARBrowser-unsigned.ipa
```

Скачай artifact и подпиши полученный IPA в ESign.

## Если Actions красный

Открой упавший workflow → job `build` → последний красный шаг.
В проекте нет приватных ключей, provisioning profile или сертификатов, поэтому для этой unsigned-сборки их добавлять в GitHub Secrets не надо.

## Ограничения

Для установки на iPhone IPA после unsigned-сборки нужно подписать ESign или другим совместимым способом.

Само приложение использует только системные iOS API: AVFoundation, Vision, CoreMotion, WebKit и UIKit.
