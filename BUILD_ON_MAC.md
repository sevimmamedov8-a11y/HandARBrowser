# Сборка IPA на Mac

Установи Xcode из App Store и открой `HandARBrowser.xcodeproj`.

Самый простой способ:

1. Выбери iPhone 13 как Run Destination.
2. Target → Signing & Capabilities → выбери свою Apple ID/Team.
3. Нажми Run и разреши камеру.
4. Для IPA запусти `Scripts/BUILD_SIGNED_IPA.command`.

Для unsigned IPA запусти `Scripts/BUILD_UNSIGNED_IPA.command`.

На Windows `DOWNLOAD_DEPENDENCIES.bat` не скачивает SDK специально: в этом проекте нет внешних библиотек. Apple SDK ставится через Xcode на Mac.

## GitHub Actions

Можно загрузить папку проекта в GitHub, открыть Actions → `Build unsigned IPA` → `Run workflow`. В артефакте появится `HandARBrowser-unsigned.ipa`.
