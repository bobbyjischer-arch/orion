"""
╔══════════════════════════════════════════════════════╗
║  O.R.I.O.N. BOT  —  Telegram интеграция (aiogram)   ║
║  Синхронизируется с core через REST API              ║
╚══════════════════════════════════════════════════════╝
"""

import os
import json
import asyncio
import logging
from pathlib import Path
from datetime import datetime
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import Message, CallbackQuery, InlineKeyboardMarkup, InlineKeyboardButton
import httpx
from dotenv import load_dotenv

from core.assistant import FinanceTracker, SmartHome

load_dotenv()

logging.basicConfig(level=logging.INFO, format='[%(asctime)s] %(levelname)s: %(message)s')
log = logging.getLogger(__name__)

CORE_URL = os.getenv("CORE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TELEGRAM_TOKEN")
POLL_INTERVAL = 15            # секунд между проверками событий
CHECK_TIMEOUT = 120           # секунд ожидания ответа на опрос до эскалации

if not BOT_TOKEN:
    raise ValueError("❌ TELEGRAM_TOKEN не установлен")

# ── Авторизация владельца ────────────────────────────────────────────
# Кто может управлять ботом. Раньше любой, кто напишет /start, «угонял»
# систему (last-writer-wins). Теперь владелец фиксируется:
#   • если OWNER_CHAT_ID задан в .env — только он;
#   • иначе — первый, кто выполнил /start (Trust-On-First-Use), и запись
#     сохраняется в owner.json.
OWNER_FILE = Path(__file__).parent / "owner.json"


def _load_owner() -> int | None:
    env = os.getenv("OWNER_CHAT_ID", "").strip()
    if env:
        try:
            return int(env)
        except ValueError:
            pass
    try:
        if OWNER_FILE.exists():
            return int(json.loads(OWNER_FILE.read_text(encoding="utf-8"))["owner"])
    except Exception:
        pass
    return None


def _save_owner(chat_id: int):
    try:
        OWNER_FILE.write_text(json.dumps({"owner": chat_id}), encoding="utf-8")
    except Exception as e:
        log.error(f"❌ Не удалось сохранить владельца: {e}")


owner_chat_id: int | None = None


def is_owner(chat_id: int) -> bool:
    return owner_chat_id is not None and chat_id == owner_chat_id

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()
registered_chat_id: int | None = None

# Доверенные контакты для эскалации: [{chat_id, name}]
CONTACTS_FILE = Path(__file__).parent / "contacts.json"
emergency_contacts: list[dict] = []

# Активный опрос состояния: {"ts", "lat", "lon", "task"}.
# Пока он есть и не отвечен — по таймауту произойдёт эскалация.
active_check: dict | None = None

# Персональный помощник: финтрекер (с детекцией подозрительных операций) + умный дом.
finance = FinanceTracker(path=str(Path(__file__).parent / "finance_ledger.json"))
smart_home = SmartHome()


# ── Контакты (персистентность) ───────────────────────────────────────

def load_contacts():
    global emergency_contacts
    try:
        if CONTACTS_FILE.exists():
            emergency_contacts = json.loads(CONTACTS_FILE.read_text(encoding="utf-8"))
    except Exception as e:
        log.error(f"❌ Не удалось загрузить контакты: {e}")
        emergency_contacts = []


def save_contacts():
    try:
        CONTACTS_FILE.write_text(
            json.dumps(emergency_contacts, ensure_ascii=False, indent=2),
            encoding="utf-8"
        )
    except Exception as e:
        log.error(f"❌ Не удалось сохранить контакты: {e}")


# ── Команды бота ─────────────────────────────────────────────────────

@dp.message(Command("start"))
async def cmd_start(message: Message):
    """Регистрация бота в core (только владелец)."""
    global registered_chat_id, owner_chat_id
    chat_id = message.chat.id
    user_name = message.from_user.first_name or "User"

    # Trust-On-First-Use: первый /start закрепляет владельца.
    if owner_chat_id is None:
        owner_chat_id = chat_id
        _save_owner(chat_id)
        log.info(f"🔐 Владелец закреплён: chat_id={chat_id}")
    elif not is_owner(chat_id):
        log.warning(f"⛔ Чужой /start отклонён: chat_id={chat_id}")
        await message.answer("⛔ Этот бот привязан к другому владельцу.")
        return

    async with httpx.AsyncClient() as client:
        try:
            resp = await client.post(f"{CORE_URL}/register", json={
                "chat_id": chat_id,
                "name": user_name
            }, timeout=10)
            resp.raise_for_status()
            data = resp.json()
            registered_chat_id = chat_id

            await message.answer(
                f"✅ *O.R.I.O.N. активирован*\n\n"
                f"🔗 Подключен к core\n"
                f"📊 Событий в очереди: {data.get('queued_events', 0)}\n"
                f"🆔 Chat ID: `{chat_id}`\n\n"
                f"Теперь ты будешь получать уведомления о тревогах и SOS.",
                parse_mode="Markdown"
            )
            log.info(f"✅ Зарегистрирован: chat_id={chat_id}, name={user_name}")

            # Режим «Анализирую» — сразу запускаем анализ маршрута
            await message.answer("🛰 _Анализирую…_", parse_mode="Markdown")
            await _run_startup_analysis(message)
        except Exception as e:
            log.error(f"❌ Ошибка регистрации: {e}")
            await message.answer(
                f"❌ Не удалось подключиться к core:\n`{e}`",
                parse_mode="Markdown"
            )


@dp.message(Command("status"))
async def cmd_status(message: Message):
    """Статус системы."""
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.get(f"{CORE_URL}/api/status", timeout=5)
            resp.raise_for_status()
            data = resp.json()

            bot_info = data.get("bot", {})
            alert_active = data.get("alert_active", False)

            msg = (
                f"📡 *O.R.I.O.N. Status*\n\n"
                f"🟢 Core: {data.get('status', 'unknown')}\n"
                f"📍 Точек сохранено: {data.get('points_stored', 0)}\n"
                f"🚨 Тревога: {'Активна' if alert_active else 'Нет'}\n"
                f"🤖 Бот: {bot_info.get('status', 'unknown')}\n"
                f"🔄 Переподключений: {bot_info.get('reconnects', 0)}"
            )
            await message.answer(msg, parse_mode="Markdown")
        except Exception as e:
            await message.answer(f"❌ Ошибка: `{e}`", parse_mode="Markdown")


@dp.message(Command("check"))
async def cmd_check(message: Message):
    """Разовый анализ подозрений по последней известной точке."""
    async with httpx.AsyncClient() as client:
        try:
            # Берём последнюю точку из истории core
            hist = await client.get(f"{CORE_URL}/location/history", params={"limit": 1}, timeout=5)
            hist.raise_for_status()
            points = hist.json().get("points", [])
            if not points:
                await message.answer("📍 Пока нет ни одной точки для анализа.")
                return

            last = points[-1]
            ts = last.get("timestamp", "")
            local_time = ts[11:16] if len(ts) >= 16 else ""

            resp = await client.post(f"{CORE_URL}/analyze/suspicion", json={
                "latitude":   last["latitude"],
                "longitude":  last["longitude"],
                "local_time": local_time,
            }, timeout=25)
            resp.raise_for_status()
            a = resp.json()

            bar = _suspicion_bar(a.get("suspicion", 0))
            msg = (
                f"🧠 *Анализ O.R.I.O.N.*\n\n"
                f"{bar} *{a.get('suspicion', 0)}/100*\n"
                f"📝 {a.get('reason', '—')}\n"
                f"_(источник: {a.get('source', '?')})_"
            )
            if a.get("voice"):
                msg += f"\n\n💬 _{a['voice']}_"
            if a.get("should_ask") and a.get("question"):
                msg += f"\n\n❓ {a['question']}"
            await message.answer(msg, parse_mode="Markdown")
        except Exception as e:
            await message.answer(f"❌ Ошибка анализа: `{e}`", parse_mode="Markdown")


@dp.message(Command("brain"))
async def cmd_brain(message: Message):
    """Статус «мозга»: автономный AEGIS + доступность нейросетей."""
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.get(f"{CORE_URL}/aegis/status", timeout=10)
            resp.raise_for_status()
            b = resp.json()
            mode = "усилен нейросетью" if b.get("neural_augmented") else "автономный режим"
            ollama_ok = "🟢" if b.get("ollama", {}).get("reachable") else "⚪️"
            cloud_ok = "🟢" if b.get("openrouter", {}).get("has_key") else "⚪️"
            counter = b.get("counter", {}).get("level", 0)
            await message.answer(
                f"🧠 *{b.get('callsign', 'AEGIS')}* — {mode}\n\n"
                f"Активный бэкенд: `{b.get('active', '?')}`\n"
                f"{ollama_ok} Ollama (локальная нейросеть)\n"
                f"{cloud_ok} OpenRouter (облако)\n"
                f"📈 Счётчик подозрений: *{counter}/100*\n\n"
                f"_Автономное ядро работает всегда — нейросеть лишь усиливает его._",
                parse_mode="Markdown",
            )
        except Exception as e:
            await message.answer(f"❌ Ошибка: `{e}`", parse_mode="Markdown")


def _suspicion_bar(level: int) -> str:
    """Визуальная шкала подозрения 0..100 из 10 блоков."""
    filled = max(0, min(10, round(level / 10)))
    emoji = "🟩" if level < 40 else ("🟨" if level < 60 else "🟥")
    return emoji * filled + "⬜️" * (10 - filled)


async def _run_startup_analysis(message: Message):
    """Первичный анализ маршрута при подключении (режим «Анализирую»)."""
    async with httpx.AsyncClient() as client:
        try:
            hist = await client.get(f"{CORE_URL}/location/history", params={"limit": 1}, timeout=5)
            hist.raise_for_status()
            points = hist.json().get("points", [])
            if not points:
                await message.answer("📍 Пока нет данных о маршруте — жду первую точку от приложения.")
                return

            last = points[-1]
            ts = last.get("timestamp", "")
            local_time = ts[11:16] if len(ts) >= 16 else ""

            resp = await client.post(f"{CORE_URL}/analyze/suspicion", json={
                "latitude":   last["latitude"],
                "longitude":  last["longitude"],
                "local_time": local_time,
            }, timeout=25)
            resp.raise_for_status()
            a = resp.json()

            bar = _suspicion_bar(a.get("suspicion", 0))
            msg = (
                f"🧠 *Первичная оценка*\n\n"
                f"{bar} *{a.get('suspicion', 0)}/100*\n"
                f"📝 {a.get('reason', '—')}"
            )
            if a.get("should_ask") and a.get("question"):
                msg += f"\n\n❓ {a['question']}"
            await message.answer(msg, parse_mode="Markdown")
        except Exception as e:
            log.error(f"❌ Ошибка первичного анализа: {e}")


@dp.message(Command("sos"))
async def cmd_sos(message: Message):
    """Экстренный пульт: мгновенно оповестить доверенные контакты."""
    if not is_owner(message.chat.id):
        return
    lat = lon = None
    async with httpx.AsyncClient() as client:
        try:
            hist = await client.get(f"{CORE_URL}/location/history", params={"limit": 1}, timeout=5)
            points = hist.json().get("points", [])
            if points:
                lat, lon = points[-1]["latitude"], points[-1]["longitude"]
        except Exception:
            pass
    await message.answer("🆘 Поднимаю тревогу и оповещаю контакты…")
    await escalate_to_contacts(lat, lon, reason="Ручной вызов SOS через бота")


@dp.message(Command("contacts"))
async def cmd_contacts(message: Message):
    """Список доверенных контактов."""
    if not emergency_contacts:
        await message.answer("📇 Контактов нет. Добавь: `/addcontact <chat_id> <имя>`", parse_mode="Markdown")
        return
    lines = "\n".join(f"• {c['name']} — `{c['chat_id']}`" for c in emergency_contacts)
    await message.answer(f"📇 *Доверенные контакты:*\n{lines}", parse_mode="Markdown")


@dp.message(Command("addcontact"))
async def cmd_addcontact(message: Message):
    """Добавить контакт: /addcontact <chat_id> <имя>."""
    if not is_owner(message.chat.id):
        return
    parts = (message.text or "").split(maxsplit=2)
    if len(parts) < 3:
        await message.answer("Использование: `/addcontact <chat_id> <имя>`", parse_mode="Markdown")
        return
    try:
        chat_id = int(parts[1])
    except ValueError:
        await message.answer("❌ chat_id должен быть числом.")
        return
    name = parts[2].strip()
    if any(c["chat_id"] == chat_id for c in emergency_contacts):
        await message.answer("⚠️ Такой контакт уже есть.")
        return
    emergency_contacts.append({"chat_id": chat_id, "name": name})
    save_contacts()
    await message.answer(f"✅ Добавлен контакт: {name} (`{chat_id}`)", parse_mode="Markdown")


@dp.message(Command("delcontact"))
async def cmd_delcontact(message: Message):
    """Удалить контакт: /delcontact <chat_id>."""
    if not is_owner(message.chat.id):
        return
    parts = (message.text or "").split(maxsplit=1)
    if len(parts) < 2:
        await message.answer("Использование: `/delcontact <chat_id>`", parse_mode="Markdown")
        return
    try:
        chat_id = int(parts[1].strip())
    except ValueError:
        await message.answer("❌ chat_id должен быть числом.")
        return
    before = len(emergency_contacts)
    emergency_contacts[:] = [c for c in emergency_contacts if c["chat_id"] != chat_id]
    save_contacts()
    await message.answer("✅ Удалён." if len(emergency_contacts) < before else "⚠️ Контакт не найден.")


@dp.message(Command("health"))
async def cmd_health(message: Message):
    """Мед-анализ состояния. Формат:
    /health <шаги> <вес_кг> <сон_ч> <настроение1-5> <стресс1-5>
    Любой параметр можно пропустить, поставив прочерк (-).
    """
    parts = (message.text or "").split()
    if len(parts) < 2:
        await message.answer(
            "❤️ *Мед-анализ состояния*\n\n"
            "Формат: `/health <шаги> <вес> <сон_ч> <настроение 1-5> <стресс 1-5>`\n"
            "Пример: `/health 8500 72.5 7 4 2`\n"
            "Пропуск параметра — прочерк: `/health 8500 - 6 3 4`\n\n"
            "_Не является медицинской консультацией._",
            parse_mode="Markdown"
        )
        return

    def num(idx, cast):
        if idx < len(parts) and parts[idx] != "-":
            try:
                return cast(parts[idx])
            except ValueError:
                return None
        return None

    body = {
        "steps":       num(1, int) or 0,
        "weight_kg":   num(2, float),
        "sleep_hours": num(3, float),
        "mood":        num(4, int),
        "stress":      num(5, int),
    }

    async with httpx.AsyncClient() as client:
        try:
            resp = await client.post(f"{CORE_URL}/analyze/health", json=body, timeout=30)
            resp.raise_for_status()
            a = resp.json()
            recs = "\n".join(f"• {r}" for r in a.get("recommendations", []))
            msg = (
                f"❤️ *Состояние: {a.get('score', 0)}/100*\n"
                f"_(источник: {a.get('source', '?')})_\n\n"
                f"{a.get('summary', '—')}\n"
            )
            if recs:
                msg += f"\n{recs}"
            await message.answer(msg, parse_mode="Markdown")
        except Exception as e:
            await message.answer(f"❌ Ошибка анализа: `{e}`", parse_mode="Markdown")


# ── Персональный помощник: финтрекер + умный дом ─────────────────────

@dp.message(Command("spend"))
async def cmd_spend(message: Message):
    """Записать операцию: /spend <сумма> [категория]. Отрицательная — трата.
    Помечает подозрительные операции (крупные/ночные/серии)."""
    if not is_owner(message.chat.id):
        return
    parts = (message.text or "").split(maxsplit=2)
    if len(parts) < 2:
        await message.answer(
            "💳 *Финтрекер*\nФормат: `/spend <сумма> [категория]`\n"
            "Пример: `/spend -1500 такси` (трата), `/spend 50000 зарплата` (доход)",
            parse_mode="Markdown")
        return
    try:
        amount = float(parts[1].replace(",", "."))
    except ValueError:
        await message.answer("❌ Сумма должна быть числом.")
        return
    category = parts[2] if len(parts) > 2 else ""
    rec = finance.add_transaction(amount, category)
    txt = f"✅ Записано: {amount:+.2f} {category}".strip()
    if rec["flags"]:
        txt += "\n⚠️ *Подозрительно:* " + ", ".join(rec["flags"])
        # Подозрительная транзакция — сигнал безопасности владельцу.
    await message.answer(txt, parse_mode="Markdown")


@dp.message(Command("finance"))
async def cmd_finance(message: Message):
    """Сводка финансов за 30 дней + подозрительные операции."""
    if not is_owner(message.chat.id):
        return
    s = finance.summary(days=30)
    lines = [
        "💰 *Финансы за 30 дней*",
        f"Доход: {s['income']:+.0f}",
        f"Расход: {s['spend']:+.0f}",
        f"Итог: {s['net']:+.0f}  ·  операций: {s['count']}",
    ]
    susp = s.get("suspicious", [])
    if susp:
        lines.append(f"\n⚠️ *Подозрительных: {len(susp)}*")
        for t in susp[-5:]:
            lines.append(f"• {t['amount']:+.0f} {t.get('category','')} — {', '.join(t['flags'])}")
    await message.answer("\n".join(lines), parse_mode="Markdown")


@dp.message(Command("home"))
async def cmd_home(message: Message):
    """Умный дом (заглушка): /home <устройство> <состояние> | /home scene <имя>."""
    if not is_owner(message.chat.id):
        return
    parts = (message.text or "").split(maxsplit=2)
    if len(parts) < 2:
        devices = smart_home.list_devices()
        state = "\n".join(f"• {k}: {v}" for k, v in devices.items()) or "нет устройств"
        await message.answer(
            f"🏠 *Умный дом*\n{state}\n\n"
            "`/home <устройство> <вкл|выкл>` · `/home scene <дом|уход|тревога>`",
            parse_mode="Markdown")
        return
    if parts[1] == "scene" and len(parts) > 2:
        res = smart_home.scene(parts[2])
        await message.answer(f"🏠 Сцена «{parts[2]}»: {res}")
        return
    if len(parts) > 2:
        smart_home.set_state(parts[1], parts[2])
        await message.answer(f"🏠 {parts[1]} → {parts[2]}")
    else:
        await message.answer("Формат: `/home <устройство> <состояние>`", parse_mode="Markdown")


@dp.message(Command("help"))
async def cmd_help(message: Message):
    """Справка."""
    await message.answer(
        "🛡️ *O.R.I.O.N. Commands*\n\n"
        "/start — Подключить бота и запустить анализ\n"
        "/status — Статус системы\n"
        "/check — Анализ: нужна ли помощь сейчас\n"
        "/brain — Статус «мозга» (AEGIS + нейросети)\n"
        "/health — Анализ состояния (шаги/вес/сон/настроение)\n"
        "/sos — Экстренно оповестить доверенные контакты\n"
        "/contacts — Список доверенных контактов\n"
        "/addcontact <chat\\_id> <имя> — Добавить контакт\n"
        "/delcontact <chat\\_id> — Удалить контакт\n"
        "/spend <сумма> [кат] — Записать операцию (финтрекер)\n"
        "/finance — Сводка финансов + подозрительные операции\n"
        "/home — Управление умным домом (заглушка)\n"
        "/help — Эта справка\n\n"
        "При росте «счётчика подозрений» бот задаёт контрольный вопрос. "
        "Если не ответить — автоматически оповещает доверенные контакты.",
        parse_mode="Markdown"
    )


# ── Фоновый поллинг событий ─────────────────────────────────────────

async def poll_events():
    """Периодически проверяет события от core и отправляет в Telegram."""
    log.info("🔄 Запущен поллинг событий от core")

    while True:
        await asyncio.sleep(POLL_INTERVAL)

        if not registered_chat_id:
            continue

        async with httpx.AsyncClient() as client:
            try:
                # Обновляем статус бота
                await client.post(f"{CORE_URL}/bot/status", json={
                    "status": "polling",
                    "note": f"active, chat_id={registered_chat_id}",
                    "ts": datetime.now().isoformat()
                }, timeout=5)

                # Получаем события
                resp = await client.get(f"{CORE_URL}/bot/events", timeout=5)
                resp.raise_for_status()
                data = resp.json()
                events = data.get("events", [])

                if not events:
                    continue

                log.info(f"📬 Получено событий: {len(events)}")

                for event in events:
                    await handle_event(event)

            except Exception as e:
                log.error(f"❌ Ошибка поллинга: {e}")


async def handle_event(event: dict):
    """Обработка события от core."""
    event_type = event.get("type")

    if event_type == "alert":
        await send_alert(event)
    elif event_type == "sos":
        await send_sos(event)
    elif event_type == "suspicion":
        await send_suspicion(event)
    else:
        log.warning(f"⚠️ Неизвестный тип события: {event_type}")


async def send_alert(event: dict):
    """Отправка тревоги."""
    if not registered_chat_id:
        return

    lat = event.get("latitude")
    lon = event.get("longitude")
    reason = event.get("reason", "Неизвестная причина")
    level = event.get("level", 1)

    maps_link = f"https://maps.google.com/?q={lat},{lon}"

    emoji = "🚨" if level >= 3 else "⚠️"
    msg = (
        f"{emoji} *ТРЕВОГА*\n\n"
        f"📝 {reason}\n"
        f"📍 [Местоположение]({maps_link})\n"
        f"🕐 {datetime.now().strftime('%H:%M:%S')}"
    )

    try:
        await bot.send_message(
            chat_id=registered_chat_id,
            text=msg,
            parse_mode="Markdown"
        )
        log.info(f"🚨 Тревога отправлена: {reason}")
    except Exception as e:
        log.error(f"❌ Ошибка отправки тревоги: {e}")


def _check_keyboard() -> InlineKeyboardMarkup:
    """Кнопки опроса состояния."""
    return InlineKeyboardMarkup(inline_keyboard=[[
        InlineKeyboardButton(text="✅ Я в порядке", callback_data="check:ok"),
        InlineKeyboardButton(text="🆘 Нужна помощь", callback_data="check:help"),
    ]])


async def send_suspicion(event: dict):
    """Опрос состояния при высоком уровне подозрения + таймер эскалации."""
    global active_check
    if not registered_chat_id:
        return

    level = event.get("suspicion", 0)
    reason = event.get("reason", "—")
    question = event.get("question") or "Всё ли с тобой хорошо?"
    lat, lon = event.get("latitude"), event.get("longitude")

    bar = _suspicion_bar(level)
    msg = (
        f"🧠 *O.R.I.O.N. — повышенное внимание*\n\n"
        f"{bar} *{level}/100*\n"
        f"📝 {reason}\n"
    )
    if event.get("voice"):
        msg += f"💬 _{event['voice']}_\n"
    if lat is not None and lon is not None:
        msg += f"📍 [Местоположение](https://maps.google.com/?q={lat},{lon})\n"
    msg += f"\n❓ {question}\n\n_Ответь в течение {CHECK_TIMEOUT // 60} мин, иначе будет поднята тревога._"

    try:
        await bot.send_message(
            chat_id=registered_chat_id, text=msg,
            parse_mode="Markdown", reply_markup=_check_keyboard()
        )
        log.info(f"🧠 Опрос отправлен: {level}/100")

        # Перезапускаем таймер ожидания ответа
        if active_check and active_check.get("task"):
            active_check["task"].cancel()
        active_check = {"ts": datetime.now().isoformat(), "lat": lat, "lon": lon, "task": None}
        active_check["task"] = asyncio.create_task(_escalate_after_timeout(lat, lon))
    except Exception as e:
        log.error(f"❌ Ошибка отправки опроса: {e}")


async def _escalate_after_timeout(lat, lon):
    """Если на опрос нет ответа за CHECK_TIMEOUT — эскалация к контактам."""
    global active_check
    try:
        await asyncio.sleep(CHECK_TIMEOUT)
    except asyncio.CancelledError:
        return  # пользователь ответил — таймер отменён
    log.warning("⏰ Нет ответа на опрос — эскалация")
    if registered_chat_id:
        try:
            await bot.send_message(
                chat_id=registered_chat_id,
                text="⏰ *Нет ответа.* Оповещаю доверенные контакты.",
                parse_mode="Markdown"
            )
        except Exception:
            pass
    await escalate_to_contacts(lat, lon, reason="Нет ответа на проверку состояния")
    active_check = None


@dp.callback_query(F.data.startswith("check:"))
async def on_check_answer(cb: CallbackQuery):
    """Обработка ответа пользователя на опрос состояния."""
    global active_check
    answer = cb.data.split(":", 1)[1]

    # Останавливаем таймер эскалации
    if active_check and active_check.get("task"):
        active_check["task"].cancel()
    lat = active_check.get("lat") if active_check else None
    lon = active_check.get("lon") if active_check else None
    active_check = None

    if answer == "ok":
        await cb.message.edit_text("✅ Принято. Рад, что всё хорошо.")
        await cb.answer("Тревога отменена")
    elif answer == "help":
        await cb.message.edit_text("🆘 Принято. Поднимаю тревогу и оповещаю контакты.")
        await cb.answer("Оповещаю контакты", show_alert=True)
        await escalate_to_contacts(lat, lon, reason="Пользователь запросил помощь")


async def escalate_to_contacts(lat, lon, reason: str):
    """Оповестить все доверенные контакты о ситуации."""
    if not emergency_contacts:
        if registered_chat_id:
            await bot.send_message(
                chat_id=registered_chat_id,
                text="⚠️ Нет доверенных контактов для оповещения. Добавь их: /addcontact",
            )
        return

    maps = f"https://maps.google.com/?q={lat},{lon}" if lat is not None else "местоположение неизвестно"
    text = (
        f"🆘 *O.R.I.O.N. — требуется помощь*\n\n"
        f"📝 {reason}\n"
        f"📍 [Местоположение]({maps})\n"
        f"🕐 {datetime.now().strftime('%H:%M:%S')}\n\n"
        f"Это автоматическое оповещение системы безопасности."
    )
    sent = 0
    for c in emergency_contacts:
        try:
            await bot.send_message(chat_id=c["chat_id"], text=text, parse_mode="Markdown")
            sent += 1
        except Exception as e:
            log.error(f"❌ Контакт {c.get('name')} ({c.get('chat_id')}): {e}")

    if registered_chat_id:
        await bot.send_message(
            chat_id=registered_chat_id,
            text=f"📨 Оповещено контактов: {sent}/{len(emergency_contacts)}"
        )
    log.info(f"🆘 Эскалация: оповещено {sent}/{len(emergency_contacts)}")


async def send_sos(event: dict):
    """Отправка SOS."""
    if not registered_chat_id:
        return

    lat = event.get("latitude")
    lon = event.get("longitude")
    source = event.get("source", "unknown")
    maps_link = event.get("maps", f"https://maps.google.com/?q={lat},{lon}")

    msg = (
        f"🆘 *SOS СИГНАЛ*\n\n"
        f"📱 Источник: {source}\n"
        f"📍 [Местоположение]({maps_link})\n"
        f"🕐 {datetime.now().strftime('%H:%M:%S')}\n\n"
        f"⚡️ Требуется немедленная помощь!"
    )

    try:
        await bot.send_message(
            chat_id=registered_chat_id,
            text=msg,
            parse_mode="Markdown"
        )
        log.info(f"🆘 SOS отправлен от {source}")
    except Exception as e:
        log.error(f"❌ Ошибка отправки SOS: {e}")


# ── Запуск ───────────────────────────────────────────────────────────

async def main():
    log.info("🚀 Запуск O.R.I.O.N. Telegram Bot (aiogram)")
    log.info(f"🔗 Core URL: {CORE_URL}")

    global owner_chat_id
    owner_chat_id = _load_owner()
    if owner_chat_id:
        log.info(f"🔐 Владелец: chat_id={owner_chat_id}")
    else:
        log.info("🔐 Владелец не задан — закрепится при первом /start")

    load_contacts()
    log.info(f"📇 Загружено контактов: {len(emergency_contacts)}")

    # Запуск фонового поллинга
    asyncio.create_task(poll_events())

    log.info("✅ Бот готов к работе")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
