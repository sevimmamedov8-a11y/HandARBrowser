# HandARBrowser V56 — исправление сборки

Исправлена единственная блокирующая ошибка сборки V55 в MainViewController.swift.

Было:
`context.eoFillPath()`

В Xcode 26.6 у CGContext нет метода `eoFillPath()`. Для сохранения той же even-odd заливки используется:
`context.drawPath(using: .eoFill)`

Изменён только этот вызов и номер сборки:
CFBundleVersion = 56.

Предупреждения `WKProcessPool` и `controller.gamepad` не являются причиной падения сборки.
