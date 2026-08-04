# O.R.I.O.N. — развёртывание

Канонический стек: **этот каталог (`orion_final`)** — core (FastAPI) + bot (aiogram)
+ дашборд. Состояние в памяти, без БД. Ниже — локальный запуск и публикация
наружу через Cloudflare Tunnel (устойчиво к блокировкам, сохраняет SSE).

## 0. Секреты (обязательно)

```bash
cp .env.example .env
# заполни: TELEGRAM_TOKEN, SECRET_CODE, ORION_API_KEY, ORION_CASCADE_SECRET
python -c "import secrets;print('ORION_API_KEY     =', secrets.token_urlsafe(32))"
python -c "import secrets;print('ORION_CASCADE_SECRET =', secrets.token_urlsafe(32))"
```

- `ORION_API_KEY` — общий ключ для защищённых эндпоинтов (iOS/бот шлют в `X-Orion-Key`).
  Пусто → auth выключен (только localhost-разработка).
- `ORION_CASCADE_SECRET` — общий секрет каскадного шифрования (`/secure/ingest`).
  Тот же секрет надо положить в Keychain приложения (`cascadeSecret`).
- `OWNER_CHAT_ID` — Telegram ID владельца бота. Пусто → владельцем станет первый `/start`.

> ⚠️ Ранее в репозитории лежал живой токен бота — он **отозван/сменён** через @BotFather.
> Никогда не коммить `.env`.

## 1. Локальный запуск (без Docker)

```bash
pip install -r requirements.txt
# терминал 1 — core
ORION_API_KEY=... ORION_CASCADE_SECRET=... uvicorn core.main:app --host 0.0.0.0 --port 8080
# терминал 2 — bot
CORE_URL=http://localhost:8080 TELEGRAM_TOKEN=... python bot.py
```

Дашборд: <http://localhost:8080>. Проверка: `curl localhost:8080/api/status`.

Опционально собери C++ ядро шифрования (ускоряет расшифровку):
```bash
cmake -S core/native -B core/native/build && cmake --build core/native/build --config Release
ctest --test-dir core/native/build --output-on-failure   # known-answer тест
```
Без сборки всё работает на чистом Python (идентичный результат).

## 2. Локальный запуск (Docker)

```bash
docker compose up -d --build          # core на :8080 + bot
docker compose logs -f core
```

## 3. Публикация наружу — Cloudflare Tunnel

SSE и long-polling бота — долгоживущие соединения; Pages/Workers их не держат,
поэтому backend остаётся контейнером/процессом, а наружу его выводит туннель.

**Через токен (проще):**
1. Cloudflare Zero Trust → Networks → Tunnels → создать туннель, привязать
   hostname (напр. `orion.example.com`) к `http://core:8080`.
2. Скопировать токен туннеля в `.env` как `TUNNEL_TOKEN`.
3. `docker compose --profile tunnel up -d`

**Через конфиг на хосте:** см. `deploy/cloudflared-config.example.yml`.

## 4. Устойчивость к блокировкам (censorship resistance)

- **Cloudflare edge** терминирует TLS и скрывает origin-IP; соединение к origin
  инициирует сам туннель (исходящее) — нет открытых входящих портов.
- **Резервные каналы:** приложение шлёт SOS дублировано (сервер + напрямую
  Telegram Bot API), а бот при недоступности core уходит в прямой Telegram.
- **Прикладное шифрование** (`/secure/ingest`) не зависит от того, кто терминирует
  TLS: payload читаем только сервером с общим секретом.
- Для регионов с DPI: держи запасной hostname туннеля и/или второй relay;
  переключение — сменой `serverURL` в приложении.

## 5. Прод-чеклист безопасности

- [ ] `ORION_API_KEY` задан (auth включён), длинный случайный.
- [ ] `ORION_CASCADE_SECRET` задан и совпадает с Keychain приложения.
- [ ] `SECRET_CODE` сменён с `change-me`.
- [ ] `OWNER_CHAT_ID` зафиксирован (бот не «угоняется» чужим `/start`).
- [ ] `.env` не в git (проверь `.gitignore`).
- [ ] Токен бота отозван/сменён после утечки.
- [ ] `ORION_CORS_ORIGINS` — только свои домены (пусто = CORS закрыт).
- [ ] Rate limiting активен (встроен: SOS 20/мин, ingest 120/мин на IP).

## 6. Render (бесплатный тариф)

Blueprint в корне репо (`render.yaml`) поднимает один web-сервис `orion-core`:
core + бот в одном процессе через `start.sh` (бот стартует, только если задан
`TELEGRAM_TOKEN`; отдельный worker на free-тарифе не нужен).

1. Запушь репозиторий на GitHub/GitLab.
2. [Dashboard Render](https://dashboard.render.com) → **New +** → **Blueprint** →
   указать репо. Render прочитает `render.yaml` и создаст сервис.
3. `ORION_API_KEY` и `ORION_CASCADE_SECRET` Render сгенерирует сам
   (`ORION_CASCADE_SECRET` затем перенеси в Keychain приложения — `cascadeSecret`).
4. Заполни руками (Render спросит при создании):
   - `SECRET_CODE` — код отмены тревоги (не `change-me`);
   - `TELEGRAM_TOKEN` — токен бота (пусто → бот не стартует, core работает);
   - `OWNER_CHAT_ID` — Telegram ID владельца;
   - `OPENROUTER_API_KEY` — ключ нейро-усиления (пусто → чистый AEGIS;
     `LLM_BACKEND=openrouter` уже задан в blueprint — Ollama на Render нет).

**Ограничения free-тарифа (честно):**

- Сервис **засыпает после ~15 минут без входящих запросов**: SSE-дашборд
  отключается, первый запрос будит сервис ~1 минуту. Для системы безопасности
  это критично — пингуй `https://<сервис>.onrender.com/api/status` внешним
  монитором (например, [UptimeRobot](https://uptimerobot.com)) раз в 5–10 минут.
- **Состояние в памяти** (локации, тревоги, счётчик подозрений) **теряется**
  при каждом сне/рестарте/деплое — БД в каноническом варианте нет.
- **Устройства, трек и память «мозга»** (`core/store.py`) пишутся на диск в
  `ORION_DATA_DIR` (по умолчанию `server/data/`), поэтому переживают сон и
  рестарт процесса. Но на free-тарифе **диск эфемерный**: при редеплое или
  переносе контейнера каталог обнуляется. Приложение держит свою локальную
  историю точек, так что на телефоне она не пропадает; чтобы данные не
  терялись и на сервере, нужен платный Persistent Disk (смонтировать и
  указать `ORION_DATA_DIR` на его путь).
- Лимит **750 часов/месяц** на аккаунт: одного постоянно живого сервиса
  хватает впритык, второй бесплатный уже не влезет.

## 7. Связать телефон с сервером

Настройка сводится к трём значениям в «Настройках → 🔑 Доступ к серверу»:

1. **Адрес сервера** — `https://<сервис>.onrender.com` (или свой домен).
2. **Ключ `ORION_API_KEY`** — возьми из окружения сервиса (Render показывает
   сгенерированное значение в **Environment**). Без него защищённые
   эндпоинты отвечают 401.
3. **`ORION_CASCADE_SECRET`** — необязательно; если задан и совпадает
   с серверным, данные шифруются каскадом поверх TLS.

Оба секрета ложатся в Keychain, а не в UserDefaults.

Проверка: после пары точек трека устройство появляется на дашборде,
а `GET /track` с заголовком `X-Orion-Key` отдаёт историю. Пустой ответ при
живом трекинге — почти всегда неверный ключ (тогда будет 401) или
неправильный адрес сервера.

Локальная проверка сервера без телефона:

```bash
cd server
python tests/test_store.py        # трек, фильтры, рестарт, шифрованный канал
python tests/test_crypto.py       # каскад: Python-эталон ↔ C++-ядро
python tests/test_aegis.py        # «мозг» офлайн
python tests/test_aegis_memory.py # память, скринеры, тренды
```
