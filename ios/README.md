# O.R.I.O.N. — iOS

iOS-часть проекта: SwiftUI-приложение + виджет. Общее описание системы —
в [корневом README](../README.md), устройство кода и принятые решения —
в [`CLAUDE.md`](../CLAUDE.md).

## Требования

- iOS 16.0+ (виджеты Live Activity — iOS 16.1+)
- Xcode 16, Swift 5
- Разрешение геолокации «Всегда» — иначе трек не пишется в фоне
- Разрешение на уведомления — для тревог и статуса сервера

## Что внутри

```
ORION/
├── ORIONApp.swift        # точка входа, jailbreak-предупреждение
├── ContentView.swift     # пять вкладок: состояние, карта, SOS, самочувствие, настройки
├── Models/               # AppLock, AppSettings, HistoryLock, HealthData, OrionPet, тема
├── Services/             # локация, сеть, SOS, Keychain, биометрия, AEGIS, шифрование, питомец
└── Views/                # экран блокировки, decoy-хранилище, карта с историей, журнал, настройки
ORIONWidget/              # виджеты экрана блокировки и домашнего экрана
ORION.xcodeproj           # objectVersion 56 — новые файлы добавляются вручную, см. CLAUDE.md
```

## Сборка

Локально (нужен macOS):

```bash
xcodebuild -project ORION.xcodeproj -scheme ORION \
  -configuration Release -sdk iphoneos -arch arm64 \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Без macOS — сборку делает CI на каждый push (`.github/workflows/build.yml`),
готовый неподписанный `.ipa` лежит в артефакте `ORION-IPA`.

## Установка на iPhone

Пошагово, с Windows и без Mac — [`Installation.md`](Installation.md).

## Первый запуск

Приложение попросит придумать код доступа и повторить его: предустановленного
кода нет намеренно, исходники открыты. Неверный код открывает ложное
хранилище файлов, а не сообщает об ошибке — вход из него тот же: набрать
свой код в строке поиска. Код тревоги («тихий сигнал») задаётся отдельно
в настройках и внешне открывает приложение как обычно, но скрытно
отправляет SOS.

Дальше — адрес сервера и ключ `X-Orion-Key` в настройках, разрешение
геолокации «Всегда», контакты для SOS.
