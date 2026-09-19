# Сборка IPA через GitHub

Проект собирается в GitHub Actions на macOS runner. На Windows сборка проекта локально не требуется.

Структура репозитория:

```text
HandARBrowser.xcodeproj/
HandARBrowser/
Scripts/
.github/
```

После `commit + push` workflow автоматически запускает `xcodebuild` и собирает unsigned IPA.

Artifact:

```text
HandARBrowser-IPA
└── HandARBrowser-unsigned.ipa
```

После этого IPA можно подписать через ESign.

Перед сборкой workflow проверяет, что проект содержит ARKit World Tracking, RealityKit, `ARAnchor`, `AnchorEntity(anchor:)`, две независимые `EyeDisplayView`, а также отсутствие старых круглых масок.
