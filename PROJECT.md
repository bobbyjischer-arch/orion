# PROJECT.md — O.R.I.O.N.

Technical reference and architecture notes.

## What this is

**O.R.I.O.N.** is a personal-safety / duress system for at-risk people. Defensive use case:
panic button, silent distress, decoy vault, dead-man timer, location sharing to trusted contacts.

Four cooperating parts:

```
iOS App (Swift/SwiftUI) ──HTTP──> Core Server (FastAPI) ──SSE──> Web Dashboard (browser)
                                        │
                                        ├──REST poll──> Telegram Bot (aiogram) ──> trusted contacts
                                        └──direct Telegram API (fallback when bot offline)
```

- **iOS → Core:** `POST /location/update`, `POST /sos/trigger`, `POST /alert/trigger`.
- **Core → Web:** Server-Sent Events on `GET /events/stream` (envelope `{type, data}`; types:
  `init, location, alert, alert_cleared, sos, bot_connected, bot_status`; `:`-prefixed keepalive pings).
- **Core → Bot:** bot polls `GET /bot/events` (~15s), registers via `POST /register`, reports `POST /bot/status`.
- Live core state is **in-memory** (`locations_db`, `bot_state`, `current_alert`); что терять нельзя —
  устройства, трек и память «мозга» — лежит на диске через `core/store.py`.

## Repo layout

| Part        | Path                                    | Notes |
|-------------|-----------------------------------------|-------|
| iOS app     | `ios/ORION`                             | Decoy, SafePath, duress, Keychain, Health, Suspicion, DesignSystem, журнал+история, питомец |
| iOS widget  | `ios/ORIONWidget`                       | Lock-screen / Live Activity widgets |
| iOS project | `ios/ORION.xcodeproj`                   | Built by CI; одна схема `ORION` |
| Core server | `server/core/main.py` (+ `core/*.py`)   | AEGIS brain, cascade crypto, suspicion counter, security |
| Store       | `server/core/store.py`                  | Персистентный JSON-стор устройств/трека/памяти (переживает рестарт) |
| Brain       | `server/core/aegis.py` + `core/llm.py`  | AEGIS: автономный движок (0 сети); llm.py — роутер aegis→Ollama→OpenRouter |
| Brain memory| `server/core/aegis_memory.py`           | Накопитель с затуханием, привычные места, dwell (AEGIS v2) |
| Telegram bot| `server/bot.py`                         | Survey + SOS escalation + owner lock + assistant |
| Web dashboard| `server/templates/index.html`          | Leaflet map + suspicion gauge, SSE-driven |
| Native crypto| `server/core/native/`                  | C++ cascade core (byte-compatible with `crypto.py`) |
| CI          | `.github/workflows/build.yml`           | Unsigned IPA (macos-15 / Xcode 16.4) + тесты сервера на ubuntu |

### Новый .swift → руками в project.pbxproj

`objectVersion = 56`, **синхронизированных групп Xcode 16 здесь нет** — файл,
просто лежащий на диске, в сборку не попадает. Каждый новый `.swift` требует
трёх правок: `PBXFileReference` (путь от группы `ORION`), `PBXBuildFile`,
запись в `children` группы `B4000001` и запись в фазу `Sources` (`B6000001`).
Проверка — `comm` списка `.swift` на диске со списком в pbxproj: файлов на
диске и в проекте должно быть поровну.

Раньше в проекте лежали 10 файлов, которые никогда не были в сборке и ни разу
не проходили компилятор (`DataExportService`, `FallDetectionService`,
`GeofenceService`, `MultiDeviceService`, `MultiDeviceMapView`,
`EnhancedMapHistoryView`, `SmartNotificationService`, `TrackedDevice`,
`Geofence`, `ModernWidgets`). Они удалены: непроверенный код, который никто
не вызывает, — это не «почти готовая фича», а мусор, вводящий в заблуждение.

## Код доступа и вход (открытая версия)

Предустановленного кода нет: `AppLock.init` только выставляет
`needsSetup = !keychain.hasPasscode`, а сам код создаёт владелец на первом
запуске (`setupPasscode`, экран — тот же `LockView`, ввод с повтором).
Причина в открытых исходниках: зашитый код был бы известен всем, кто их читал,
а это единственная дверь в приложение. Duress-код («тихий сигнал») по той же
причине тоже не задаётся заранее — только в настройках (`securitySection`).

- Неверный код → `DecoyVaultView` (ложное хранилище), без сообщения об ошибке.
- Вход из decoy — набрать свой код в строке поиска: `onChange` зовёт
  `AppLock.attempt`, то есть duress-код там работает так же, как на замке.
- Смена кода — `passcodeSection` в настройках (`AppLock.changePasscode`).
  Новый код не может совпасть с кодом тревоги: `attempt` проверяет duress
  первым, и такое совпадение превратило бы обычный вход в тихий SOS.

## Журнал записей и история

**Журнал.** `Models/HealthData.swift`: у всех записей (`WeightEntry`,
`MoodEntry`, `Supplement`, `NoteEntry`) есть `updatedAt` + `deleted`; плоское
представление для UI — `SyncRecord`. Удаление везде **soft-delete**: журнал —
это история, а не текущий список, и факт удаления сам по себе информация
(плюс запись можно вернуть). Разрешение конфликтов между копиями журнала —
last-write-wins по `updatedAt`. Старые файлы журнала без новых полей
читаются: у каждого типа терпимый `init(from:)` с `decodeIfPresent`.

**Код-пароль истории** (`Models/HistoryLock.swift`): смотреть историю
свободно, а править/удалять/восстанавливать — только после кода.
Хранится SHA-256 в Keychain (`Key.historyCode`); дефолтного кода нет,
первый ввод его создаёт. Верный код открывает окно на 120 с; закрывается
по таймеру, при уходе в фон и вручную.

**Персистентность сервера.** `core/store.py` пишет `data/orion_store.json`
(каталог из `ORION_DATA_DIR`) атомарно, через temp+replace; лимит
`MAX_TRACK_POINTS = 3000` точек трека на устройство. Это закрывает дыру
free-тарифа Render: `locations_db` в памяти терялся при засыпании процесса.
Без Persistent Disk каталог всё же эфемерный: переживает сон/рестарт
процесса, но не редеплой. `server/data/` и `orion_store.json` в `.gitignore` —
это персональные данные.

Тесты: `python tests/test_store.py` (32 проверки: трек, фильтры, рестарт,
память «мозга», шифрованный канал, битый файл).

## История перемещений (2026-08)

Раньше трек владельца жил только в памяти: `/location/update` клал точку
в `locations_db` и всё — после сна Render истории не оставалось. Теперь
эндпоинт пишет и в `store.add_track_point(device_id, point)`, поэтому
перемещения переживают перезапуск.

**Смотреть по дате, времени и месту** — три поверхности, один фильтр:

| Где | Как |
|-----|-----|
| API | `GET /track?device_id=&since=&until=&place=&limit=` + `GET /track/days` (обе под `require_api_key`) |
| Дашборд | `GET /?day=YYYY-MM-DD&from_time=HH:MM&to_time=HH:MM&place=` — форма + список + голубой слой трека на Leaflet |
| iOS | `Views/MapHistoryView.swift`: шторка фильтра (день, часы «с/по», место) и список истории по дням |

Ядро — `Store.track_filtered` / `Store.track_places`. Время сравнивается
**строками, обрезанными до `[:19]`**: точки приходят и с `+00:00`, и с `Z`,
и без суффикса, а такой префикс сортируется одинаково во всех трёх случаях.
Граница из одной даты (`2026-08-04`) значит «день целиком». Место ищется
подстрокой без учёта регистра.

Дашборд фильтрует **на сервере**, а не запросом к `/track` из браузера:
страница открыта без ключа, и вкомпилировать `X-Orion-Key` в HTML нельзя.
Состояние фильтра целиком в query-параметрах — ссылку можно сохранить.

Названия мест ставит **клиент**: `LocationService.resolvePlace(for:)`
(CLGeocoder, не чаще раза в минуту и только при смещении > 150 м — Apple
режет частые запросы) кладёт строку в `LocationPoint.place`, сервер её
просто хранит. Ходить в чужой геокодер с сервера незачем и не на что.
Локальный лимит истории на устройстве — `LocationService.maxHistoryPoints`
(2000, было 200: это меньше суток при точке раз в 5 минут).

## Питомец: виды и окрасы (2026-08)

Питомец — чистая векторная графика: `Views/PetSprite.swift` рисует его в
`Canvas` внутри единичного квадрата (0…1), `Services/PetEngine.swift` двигает,
`Views/PetLayer.swift` кладёт слоем поверх экрана, `Models/OrionPet.swift`
держит «личность». Новых файлов ради видов и окрасов не заводили — см.
правило про `project.pbxproj` выше.

**Виды** (`PetSpecies`): кот, пухлая кошечка (`chonky_cat`), пёс, лиса,
кролик, хомяк, пингвин, совёнок (`owl`). Пропорции каждого — в `PetLook.of(_:)`.
Совёнок рисуется своей веткой `drawOwl` (`Stance.owl`), потому что у него
нет четырёх лап и хвоста, а есть крылья, лицевой диск и кисточки (`Ears.tufts`).

**Геометрия.** Раньше корпус стоял на захардкоженном `bodyY = 0.580`, теперь
`bodyY = ground - legLength - bodyRY` (`ground = 0.90`) — иначе короткие лапки
пухлой кошечки ни на что бы не влияли (`legLength` был мёртвым полем).
Значения `legLength` подобраны так, чтобы у всех **старых** видов `bodyY`
остался ровно 0.580. Поза «сидит» тоже привязана к `ground`, а не к абсолютным
координатам, иначе у низкого корпуса лапа рисовалась бы поперёк живота.

**Окрасы** (`PetFur`, `PetSpecies.furOptions`) — только естественные цвета
вида: акцент интерфейса сюда намеренно не заведён, синий кот выглядит не как
питомец, а как сбой. Хранение — `OrionAppearance.petFurHexes` (`pet.furHexes`,
словарь `species.rawValue → "RRGGBB"`), доступ через `petFurHex(for:)` /
`setPetFur(_:for:)`. Своё поле у каждого вида: общий цвет означал бы, что
рыжий кот при смене вида становится рыжим пингвином.

Два инварианта, которые ломаются молча:

- **Первый элемент `furOptions` обязан совпадать с `fur` в `PetLook.of(_:)`.**
  Иначе свежая установка нарисует один цвет, а «выбранным» будет другой.
  `PetCompanion.furColor` возвращает `nil` для дефолтного hex — тогда путь
  отрисовки ровно тот же, что был до появления окрасов.
- **`PetLook.tintsBelly`.** Светлое брюшко выводится из шерсти, но у пингвина
  белый перёд — не производная от чёрной спины, поэтому у него флаг `false`.

Компилятора Swift на этой машине нет: соответствие `furOptions` ↔ `PetLook`
и сохранность `bodyY` проверялись скриптом по исходникам, остальное — CI.

## AEGIS v2: память, скринеры, тренды (2026-07)

Мозг перестал судить только по «здесь и сейчас»: у него появилась память,
которая копится неделями, и арифметика по журналу вместо разовых галочек.
Ядро — `server/core/aegis_memory.py`, порт один-в-один живёт в iOS
(`AegisMemory` в `Services/SuspicionService.swift`), новых файлов на iOS нет.

**Память (`AegisMemory`).** Ячейка места — координаты, округлённые до
3 знаков (~110 м). Место привычное после ≥3 визитов в ≥2 разных дня
(`HABITUAL_VISITS`/`HABITUAL_DAYS`); хранится максимум 200 мест, вытесняются
сперва непривычные. Уровень подозрения затухает к `BASELINE = 20`
с периодом полураспада 45 минут и растёт на `RISE = 0.6` пути к мгновенной
оценке. Порядок в `observe` важен: **сначала затухание, потом рост** —
иначе свежий всплеск тут же съедался бы спадом. `dwell` (минуты на одном
месте) сбрасывается при смене ячейки, скорости ≥ 0.5 м/с или разрыве
наблюдений > 30 мин.

Чтение и запись разведены: `decayed()` — чистая функция, `level()` —
только читает, время двигает исключительно `observe`. Иначе опрос статуса
из UI обнулял бы разрыв между наблюдениями и dwell перестал бы копиться.

**Новые сигналы** (`_collect_signals` / `collectSignals`): `long_dwell`
(+18 при ≥45 мин, +10 при ≥20), `known_place` (−18), `unknown_place` (+8).
`placeKnown` трёхзначен: `true` — привычное, `false` — только когда
привычные места вообще есть, иначе `nil` («сказать нечего»). Плюс три
сочетания выше старых по тревожности, первое — «ночью надолго застрял
в незнакомом месте» (+24).

**Скринеры PHQ-2 / GAD-2.** По два пункта 0..3, сумма 0..6, отсечка 3.
Заполненный скринер **заменяет** разовую отметку: PHQ-2 отменяет штраф за
`mood ≤ 2`, GAD-2 — за `stress ≥ 4`. Иначе один и тот же признак наказывался
бы дважды и шкала упиралась бы в 0. Скринер действителен 14 дней — ровно тот
период, про который он спрашивает. Сервер принимает и `[a, b]`, и словарь
с именованными пунктами.

**Тренды.** Наклон методом наименьших квадратов по индексу, минимум
4 точки. Правила: `mood(-0.15)`, `sleep_hours(-0.20)`, `steps(-300)` —
выше лучше; `stress(+0.15)` — ниже лучше. Направление «хуже»/«лучше»/«ровно»,
каждый ухудшающийся ряд снимает 5 баллов.

**Где это видно.** Сервер: `GET /suspicion/state` и `GET /aegis/status`
отдают `memory`; память кормится в `/location/update` и `/analyze/suspicion`,
на диск пишется не чаще раза в `BRAIN_SAVE_EVERY_MIN` минут (через
`store.save_brain`). iOS: память кормится каждой точкой в
`LocationService.sendPoint` (чистая арифметика, ни сети, ни геокодинга) и
свежим снимком в `SuspicionService.evaluate`; выключенный тумблер
`suspicionEnabled` останавливает и накопление истории мест — это тоже
персональные данные. Скринеры и тренды считает всегда AEGIS, даже когда
ответила нейросеть: это арифметика по журналу, доверять её модели незачем.

Обратная совместимость сквозная: все новые поля опциональны, старые вызовы
`aegis(...)` ведут себя ровно как v1, старые `health_moods.json` читаются.

Тесты: `python tests/test_aegis_memory.py` (память, скринеры, тренды,
затухание, рестарт) и `python tests/test_aegis.py`.

## Environment reality

- Dev machine is **Windows** (git-bash). **No macOS / Xcode here** → Swift code cannot be
  compiled or run locally. iOS changes are verified by review + the GitHub Actions IPA build, not locally.
- Python (server + bot) and C++ (native core) **can** be run/tested locally on Windows.
  CI runs the four Python suites on ubuntu on every push — that check is not optional.
- App Group id: `group.com.stark.orion`. Keychain service prefix: `com.stark.orion.*`.

## Feature state (gap analysis)

Legend: ✅ implemented · 🟡 partial · 🔴 missing

### iOS
- ✅🟡 **Decoy vault** on wrong password (`Views/DecoyVaultView.swift`, `Models/AppLock.swift`).
  Вход из decoy теперь сверяется с Keychain, а не с зашитой строкой.
  Flaws to fix: photo tab is gray placeholders; +/reset/settings rows are no-ops; shared `DecoyContent`
  makes every file identical; per-render `random` causes a flicker "tell".
- 🟡 **Safe-Path dead-man timer** (`Services/SafePathService.swift`). Missing: background execution
  (plain `Timer` suspends when backgrounded → needs BGTask + local-notification backstop);
  `locationProvider` closure never wired; no arm/extend/confirm UI; uses a private `SOSService()` not the
  shared env object.
- 🟡 **Silent distress / duress** (`AppLock.attempt` → `triggerSilentDistress`, `KeychainService` duress code).
  Есть UI в настройках («Тихий сигнал»), по умолчанию код не задан — так и задумано.
  Missing: no secret tap-combo alternative; uses stale cached location; no local receipt of the silent send.
- ✅🟡 **Health collection** (`Services/HealthService.swift`, `Models/HealthData.swift`, `Views/HealthView.swift`).
  Pedometer/weight/mood/supplements/заметки + LLM analysis + журнал с историей
  (правка/удаление/восстановление за код-паролем, soft-delete).
  Валидированные скринеры PHQ-2 / GAD-2 есть (см. «AEGIS v2»).
  Missing: расписание напоминаний о «регулярных» тестах, HealthKit,
  полные шкалы PHQ-9 / GAD-7.
- ✅ **AEGIS on-device brain**: Swift-порт `aegis.py` внутри
  `Models/SuspicionAssessment.swift` (`SuspicionAssessment.aegis`) + `HealthAssessment.aegis`
  в `Services/LLMService.swift` — те же веса/сочетания/голос, что на сервере. Работает без ключа;
  нейросеть — второе мнение (merge = max, source `aegis+llm`); бейдж источника в StatusView/HealthView;
  ключ OpenRouter в настройках помечен опциональным.
- ✅ **AEGIS v2 на устройстве**: память, скринеры и тренды — зеркало сервера,
  без единого нового файла. `AegisMemory`/`AegisMemoryStore` в `Services/SuspicionService.swift`
  (переживает перезапуск), `MentalScreen`/`HealthTrend` в `Services/LLMService.swift`,
  ответы скринера — в `MoodEntry.phq2/gad2`, UI — тумблер «Скрининг PHQ-2 / GAD-2» в карточке
  самочувствия + строки скринеров и трендов в карточке анализа (`Views/HealthView.swift`).
- 🟡 **Каскадное шифрование исходящего трафика.** Swift-сторона есть
  (`Services/CascadeCrypto.swift` → `POST /secure/ingest`), C++-ядро на сервере тоже.
  Cert pinning present but **disabled/insecure** — empty `pinnedCertificates`
  branch accepts ANY server trust (MITM-exploitable).

### Server
- ✅🟡 **Suspicion counter** (`server/core/aegis_memory.py`). Накопитель с экспоненциальным
  затуханием, привычные места и dwell — см. «AEGIS v2». Остаётся 🟡: геосемантика зон
  по-прежнему по ключевым словам `placeType`, а не по реальной карте.
- 🔴 **Censorship resistance** (obfuscation + VPN / pluggable transports / failover). Absent.
- ✅ **AEGIS autonomous brain** (`core/aegis.py`). Fully offline situation + health analyzer:
  signals → compound-risk bonus → verdict {suspicion, reason, voice, action, confidence}. Always works —
  no key, no network, no NN required. `llm.py` routes: AEGIS base verdict, optionally *augmented* by
  Ollama (local NN) or OpenRouter (cloud) when reachable (`LLM_BACKEND=auto|ollama|openrouter`).
  Endpoints: `GET /aegis/status` (brain + backend availability + counter), brain info in `/api/status`;
  bot command `/brain`. Voice/action are threaded through SSE `suspicion_level` and bot `suspicion` events.
  Tests: `python tests/test_aegis.py` (offline). Remaining 🟡: structured lab/blood parsing.

### Telegram bot (`server/bot.py`)
- ✅ **Survey / push-questions** when suspicion rises (`send_suspicion`, `on_check_answer`) — single global
  active check, no persistence.
- ✅🟡 **SOS escalation to trusted contacts** (`cmd_sos`, `escalate_to_contacts`, `_escalate_after_timeout`).
  No persistent panic-button UI (typed `/sos` only); inbound `send_sos` notifies owner, not contacts.
- 🔴 **Personal assistant** (smart-home control, financial / suspicious-transaction tracker). Not implemented.

### Web + deploy
- 🟡 **Dashboard redesign.** Solid SSE/data contract; UI is one inline-CSS + vanilla-JS Jinja file, dated,
  no real map tiles beyond Leaflet defaults. Redesign must preserve the SSE endpoint + event schema +
  Jinja vars (`points_count`, `last_location.*`) OR refactor the backend to a JSON API in tandem.
- 🔴 **Cloudflare deploy.** BLOCKER: SSE + aiogram long-polling are long-lived stateful
  connections — Pages/Workers can't host the backend as-is. Realistic paths: (a) Cloudflare **Tunnel** in
  front of the existing Docker/VPS (keeps SSE), or (b) split: static frontend on **Pages** + backend on
  VPS/container behind a tunnel.
- ✅ **Render free deploy**: Blueprint `render.yaml` (web-сервис `orion-core`, rootDir
  `server`, plan free, healthCheck `/api/status`, `PYTHON_VERSION=3.12.7`, `LLM_BACKEND=openrouter`) +
  `server/start.sh` (core + бот в одном процессе, бот только при заданном `TELEGRAM_TOKEN`).
  Free-тариф: сон после ~15 мин простоя (нужен внешний пинг), in-memory состояние теряется —
  подробности в `server/DEPLOY.md` §6.

## Security issues to fix

1. **Weak passcode hashing**: unsalted single-iteration SHA-256 of a 4-digit PIN
   (`KeychainService.hashPasscode`) — trivially brute-forced. Use PBKDF2/Argon2 or Secure Enclave.
2. **Cert pinning disabled** (accepts any trust) — see the encryption item above.
3. **No auth** on `/location/update`, `/sos/trigger`, `/alert/trigger`; dashboard + SSE fully open.
   Защищённые эндпоинты (`/track`, `/secure/ingest`, …) закрыты `require_api_key`.
4. **No rate limiting** in every code path.
5. **Deploy port mismatch**: nginx proxies `localhost:8080` but uvicorn/Dockerfile listen on `8000`.
6. `SECRET_CODE` defaults to `0000` in `docker-compose.yml` — задайте свой перед запуском.
7. Никогда не коммитьте настоящий `.env`: в репозитории только `.env.example`.

## Conventions

- iOS: SwiftUI + Combine, `async/await`, `@MainActor`, singletons `.shared` + `@EnvironmentObject`.
  UI text is Russian. Follow existing file style; don't refactor unrelated code.
- Server/bot: FastAPI + uvicorn + aiogram v3 + httpx + jinja2 + python-dotenv.
- Match the existing terse, comment-light style. Keep changes surgical.
