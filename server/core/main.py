"""
╔══════════════════════════════════════════════════════╗
║  O.R.I.O.N. CORE  —  Центральный сервер (FastAPI)   ║
║  v2.0 — с синхронизацией бота и SSE для сайта        ║
╚══════════════════════════════════════════════════════╝
"""

from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
from datetime import datetime
from typing import Any, Dict, Optional, List, Union
from collections import deque
from pathlib import Path
import asyncio
import base64
import json
import os
import sys
import httpx
from dotenv import load_dotenv

# На Windows консоль по умолчанию cp1251 — эмодзи в логах роняют эндпоинты.
# Переводим stdout/stderr в UTF-8 с заменой непечатаемых символов.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

from core.llm import SuspicionContext, analyze_suspicion, analyze_health, backend_status
from core.suspicion import SuspicionCounter, ASK_THRESHOLD, instant_suspicion
from core.aegis_memory import AegisMemory
from core.security import require_api_key, RateLimiter, api_key_configured
from core.store import Store
from core import crypto

# Загружаем .env из корня orion_final (родитель core/)
load_dotenv(dotenv_path=Path(__file__).parent.parent / ".env")

app = FastAPI(title="O.R.I.O.N. Core", version="2.1.0")

# Рендерим шаблоны напрямую через Jinja Environment, а не через
# starlette.Jinja2Templates: сигнатура TemplateResponse менялась между
# версиями starlette (1.0 требует request первым аргументом), а LRU-кэш
# шаблонов падает на Python 3.14. Прямой рендер стабилен на всех версиях.
from jinja2 import Environment, FileSystemLoader
_jinja_env = Environment(
    loader=FileSystemLoader(str(Path(__file__).parent.parent / "templates")),
    autoescape=True,
    cache_size=0,
)

# CORS: по умолчанию закрыто. Разреши свои домены через ORION_CORS_ORIGINS
# (список через запятую). '*' с credentials — небезопасно, поэтому не дефолт.
_cors = [o.strip() for o in os.getenv("ORION_CORS_ORIGINS", "").split(",") if o.strip()]
if _cors:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=_cors,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

# Лимитеры: строгий для SOS/ingest, помягче — для аналитики.
sos_limiter = RateLimiter(limit=20, window=60.0)
ingest_limiter = RateLimiter(limit=120, window=60.0)

# Общий секрет каскадного шифрования (для /secure/ingest).
CASCADE_SECRET = os.getenv("ORION_CASCADE_SECRET", "").encode("utf-8")

# Накопительный счётчик подозрений (память между запросами).
suspicion_counter = SuspicionCounter()

# Персистентное хранилище устройств, трека и памяти «мозга».
# В отличие от locations_db переживает перезапуск процесса (сон Render).
store = Store()

# Память AEGIS: привычные места, dwell и уровень с затуханием по времени.
# Поднимаем из store — иначе после каждого сна Render «мозг» забывал бы,
# какие места для человека привычные, и снова считал бы дом незнакомым.
AEGIS_MEMORY_KEY = "aegis_memory"
aegis_memory = AegisMemory.from_dict(store.get_brain(AEGIS_MEMORY_KEY))
# Наблюдения идут потоком, а save_brain пишет весь стор целиком — сбрасываем
# память на диск не чаще раза в несколько минут. Потерять последние минуты
# dwell не страшно, привычные места копятся неделями.
BRAIN_SAVE_EVERY_MIN = 5.0
_brain_saved_at: Optional[datetime] = None


@app.on_event("startup")
async def _startup_warnings():
    if not api_key_configured():
        print("[CORE] ⚠️  ORION_API_KEY не задан — эндпоинты открыты (dev-режим).")
    if not CASCADE_SECRET:
        print("[CORE] ⚠️  ORION_CASCADE_SECRET не задан — /secure/ingest недоступен.")
    # Мозг: автономный AEGIS всегда на месте; нейросеть — если доступна.
    brain = await backend_status()
    if brain["neural_augmented"]:
        print(f"[CORE] 🧠 {brain['callsign']} онлайн, усилен нейросетью ({brain['active']}).")
    else:
        print(f"[CORE] 🧠 {brain['callsign']} онлайн в автономном режиме "
              f"(нейросеть не обнаружена — и не требуется).")

# ── Состояние системы ────────────────────────────────────────────
locations_db: List[dict]      = []
current_alert: Optional[dict] = None
registered_chat_id: Optional[int] = None

bot_state = {
    "online":    False,
    "status":    "unknown",
    "note":      "",
    "last_seen": None,
    "reconnects": 0,
}

# Очередь событий для бота (пока он офлайн)
bot_event_queue: deque = deque(maxlen=100)

# SSE подписчики — браузерные соединения
sse_subscribers: List[asyncio.Queue] = []

BOT_API_URL = "https://api.telegram.org/bot" + os.getenv("TELEGRAM_TOKEN", "")


# ── Модели ───────────────────────────────────────────────────────

class LocationUpdate(BaseModel):
    latitude: float
    longitude: float
    timestamp: Optional[datetime] = None
    source: str = "manual"
    speed_mps: Optional[float] = None   # если клиент знает — память точнее считает dwell
    device_id: str = "owner"            # чей это трек; по умолчанию — телефон владельца
    place: str = ""                     # название места (обратный геокодинг на клиенте)

class AlertPayload(BaseModel):
    level: int
    reason: str
    latitude: float
    longitude: float

class RegisterPayload(BaseModel):
    chat_id: int
    name: str = ""

class CodeConfirm(BaseModel):
    code: str

class BotStatusPayload(BaseModel):
    status: str
    note: str = ""
    ts: Optional[str] = None


# ── SSE утилиты ──────────────────────────────────────────────────

async def broadcast_sse(event_type: str, data: dict):
    payload = json.dumps({"type": event_type, "data": data, "ts": datetime.now().isoformat()})
    dead = []
    for q in sse_subscribers:
        try:
            q.put_nowait(payload)
        except asyncio.QueueFull:
            dead.append(q)
    for q in dead:
        sse_subscribers.remove(q)


async def push_bot_event(event: dict):
    event["ts"] = datetime.now().isoformat()
    bot_event_queue.append(event)
    await broadcast_sse("event", event)


# ── Telegram fallback ─────────────────────────────────────────────

async def send_telegram_direct(chat_id: int, text: str):
    """Отправка напрямую через API когда бот недоступен."""
    if not os.getenv("TELEGRAM_TOKEN"):
        return
    async with httpx.AsyncClient() as client:
        try:
            await client.post(f"{BOT_API_URL}/sendMessage", json={
                "chat_id": chat_id, "text": text, "parse_mode": "Markdown"
            }, timeout=5)
        except Exception as e:
            print(f"[CORE] Telegram direct send error: {e}")


def _bot_is_stale() -> bool:
    if not bot_state["last_seen"]:
        return True
    delta = (datetime.now() - datetime.fromisoformat(bot_state["last_seen"])).total_seconds()
    return delta > 90


def _haversine_km(lat1, lon1, lat2, lon2) -> float:
    """Расстояние между двумя точками в км."""
    import math
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def _route_deviation_hint(lat: float, lon: float) -> str:
    """Грубое отклонение текущей точки от центроида истории маршрутов."""
    if len(locations_db) < 10:
        return ""   # мало данных — не оцениваем
    pts = locations_db[-200:]
    clat = sum(p["latitude"] for p in pts) / len(pts)
    clon = sum(p["longitude"] for p in pts) / len(pts)
    dist = _haversine_km(lat, lon, clat, clon)
    if dist > 15:
        return f"далеко ({dist:.0f} км)"
    if dist > 5:
        return f"умеренно ({dist:.0f} км)"
    return f"в пределах привычной зоны ({dist:.1f} км)"


def _hour_of(local_time: str) -> Optional[int]:
    try:
        return int(local_time.split(":")[0]) if local_time else None
    except (ValueError, IndexError, AttributeError):
        return None


def _remember(lat: float, lon: float, *, speed_mps: Optional[float] = None,
              hour: Optional[int] = None, place_type: str = "",
              route_deviation: str = "") -> dict:
    """Скормить памяти AEGIS одно наблюдение и вернуть её срез.

    Память кормится ДО рассуждения: dwell и «привычное место» — это вход для
    AEGIS, а не его вывод. Мгновенную оценку считаем тем же скорером, что и
    накопитель, — память не должна иметь своего мнения об обстановке.
    """
    global _brain_saved_at
    instant, _ = instant_suspicion(
        hour=hour, place_type=place_type,
        route_deviation=route_deviation, speed_mps=speed_mps,
    )
    snapshot = aegis_memory.observe(
        instant=instant, lat=lat, lon=lon, speed_mps=speed_mps,
    )
    now = datetime.now()
    if _brain_saved_at is None or (now - _brain_saved_at).total_seconds() >= BRAIN_SAVE_EVERY_MIN * 60:
        store.save_brain(AEGIS_MEMORY_KEY, aegis_memory.to_dict())
        _brain_saved_at = now
    return snapshot


# ── Страницы ─────────────────────────────────────────────────────

def _track_days(device_id: str = "") -> List[dict]:
    """Дни, за которые есть точки, и их количество — по возрастанию даты.
    Нужен и календарю фильтра на дашборде, и эндпоинту `/track/days`.
    """
    days: Dict[str, int] = {}
    for p in store.track_filtered(device_id=device_id, limit=0):
        d = str(p.get("timestamp", ""))[:10]
        if d:
            days[d] = days.get(d, 0) + 1
    return [{"date": d, "points": n} for d, n in sorted(days.items())]


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request, day: str = "", from_time: str = "",
                    to_time: str = "", place: str = ""):
    """Дашборд. Фильтр истории перемещений живёт в query-параметрах и
    считается на сервере: страница и так открыта без ключа, поэтому тянуть
    защищённый `/track` из браузера было бы либо бесполезно, либо означало бы
    вкомпилировать ключ в HTML.

    day — `YYYY-MM-DD`; from_time / to_time — `HH:MM` внутри этого дня.
    """
    since = until = ""
    if day:
        since = f"{day}T{from_time or '00:00'}:00"
        until = f"{day}T{to_time or '23:59'}:59"
    track = store.track_filtered(since=since, until=until, place=place, limit=2000)
    # Без фильтра показываем свежий хвост — иначе на карту падают тысячи точек.
    if not (day or place):
        track = track[-300:]
    return HTMLResponse(_jinja_env.get_template("index.html").render(
        request=request,
        points_count=len(locations_db),
        last_location=locations_db[-1] if locations_db else None,
        alert=current_alert,
        chat_id=registered_chat_id,
        bot_online=not _bot_is_stale(),
        bot_status=bot_state["status"],
        track=track,
        # Свежие дни сверху: смотрят почти всегда сегодняшний или вчерашний.
        track_days=list(reversed(_track_days())),
        track_places=store.track_places(),
        filter_day=day,
        filter_from=from_time,
        filter_to=to_time,
        filter_place=place,
    ))


@app.get("/api/status")
async def api_status():
    brain = await backend_status()
    return {
        "status":        "online",
        "system":        "O.R.I.O.N.",
        "version":       "2.1.0",
        "points_stored": len(locations_db),
        "alert_active":  current_alert is not None,
        "registered":    registered_chat_id is not None,
        "bot":           {**bot_state, "stale": _bot_is_stale()},
        "brain":         {"callsign": brain["callsign"], "active": brain["active"],
                          "neural_augmented": brain["neural_augmented"]},
    }


# ── Bridge: бот ↔ core ───────────────────────────────────────────

@app.post("/register")
async def register_bot(payload: RegisterPayload):
    global registered_chat_id
    registered_chat_id      = payload.chat_id
    bot_state["online"]     = True
    bot_state["last_seen"]  = datetime.now().isoformat()
    bot_state["status"]     = "online"
    bot_state["reconnects"] = bot_state["reconnects"] + 1
    print(f"[CORE] ✅ Бот подключён: chat_id={payload.chat_id}, reconnect #{bot_state['reconnects']}")

    await broadcast_sse("bot_connected", {
        "chat_id":   payload.chat_id,
        "reconnects": bot_state["reconnects"],
    })
    return {
        "status":         "registered",
        "chat_id":        payload.chat_id,
        "queued_events":  len(bot_event_queue),
    }


@app.post("/bot/status")
async def update_bot_status(payload: BotStatusPayload):
    bot_state["online"]    = True
    bot_state["status"]    = payload.status
    bot_state["note"]      = payload.note
    bot_state["last_seen"] = payload.ts or datetime.now().isoformat()
    await broadcast_sse("bot_status", {"status": payload.status, "note": payload.note})
    return {"ok": True}


@app.get("/bot/events")
async def get_bot_events():
    events = list(bot_event_queue)
    bot_event_queue.clear()
    return {"events": events, "count": len(events)}


@app.get("/bot/info")
async def bot_info():
    return {
        **bot_state,
        "stale":         _bot_is_stale(),
        "queued_events": len(bot_event_queue),
        "registered_id": registered_chat_id,
    }


# ── Геолокация ───────────────────────────────────────────────────

@app.post("/location/update")
async def receive_location(data: LocationUpdate, _auth: None = Depends(require_api_key)):
    point = {
        "latitude":  data.latitude,
        "longitude": data.longitude,
        "timestamp": (data.timestamp or datetime.now()).isoformat(),
        "source":    data.source,
    }
    if data.place:
        point["place"] = data.place
    locations_db.append(point)
    # На диск — тоже. locations_db живёт в памяти и на free-тарифе Render
    # исчезает при каждом засыпании; история перемещений, которую владелец
    # смотрит по датам, обязана переживать рестарт.
    store.add_track_point(data.device_id or "owner", point)
    # Память кормится именно здесь: поток координат — единственный регулярный
    # пульс. Если учить её только на /analyze/suspicion, dwell будет считаться
    # по редким разрозненным запросам и не будет значить ничего.
    _remember(
        data.latitude, data.longitude,
        speed_mps=data.speed_mps,
        hour=(data.timestamp or datetime.now()).hour,
        route_deviation=_route_deviation_hint(data.latitude, data.longitude),
    )
    await broadcast_sse("location", point)
    print(f"[CORE] 📍 #{len(locations_db)}: ({data.latitude:.5f}, {data.longitude:.5f})")
    return {"status": "received", "total": len(locations_db)}


@app.get("/location/history")
async def get_history(limit: int = 50):
    return {"points": locations_db[-limit:], "total": len(locations_db)}


@app.get("/track")
async def get_track(device_id: str = "", since: str = "", until: str = "",
                    place: str = "", limit: int = 500,
                    _auth: None = Depends(require_api_key)):
    """История перемещений с диска: по дате, времени и месту.

    since / until — ISO-время или просто дата (`2026-08-04`): день целиком.
    place — подстрока названия места. device_id пустой — все устройства.
    Отдаём и список известных мест, чтобы клиенту было чем наполнить фильтр.
    """
    points = store.track_filtered(
        device_id=device_id, since=since, until=until,
        place=place, limit=max(1, min(limit, 2000)),
    )
    return {
        "points":  points,
        "total":   len(points),
        "places":  store.track_places(device_id),
        "devices": sorted(store.devices().keys()),
    }


@app.get("/track/days")
async def get_track_days(device_id: str = "", _auth: None = Depends(require_api_key)):
    """Даты, за которые вообще есть точки — календарь фильтра без пустых дней."""
    return {"days": _track_days(device_id)}


# ── Тревога ──────────────────────────────────────────────────────

@app.post("/alert/trigger")
async def trigger_alert(payload: AlertPayload, _auth: None = Depends(require_api_key)):
    global current_alert
    current_alert = {
        "level":     payload.level,
        "reason":    payload.reason,
        "latitude":  payload.latitude,
        "longitude": payload.longitude,
        "triggered": datetime.now().isoformat(),
        "attempts":  0,
    }
    print(f"[CORE] 🚨 Тревога: {payload.reason}")
    await broadcast_sse("alert", current_alert)

    if _bot_is_stale() and registered_chat_id:
        # Бот недоступен — шлём напрямую через API
        maps = f"https://maps.google.com/?q={payload.latitude},{payload.longitude}"
        await send_telegram_direct(
            registered_chat_id,
            f"🚨 *ТРЕВОГА*\n_{payload.reason}_\n[Позиция]({maps})\n\n"
            f"_Бот офлайн — уведомление через core_"
        )
    else:
        await push_bot_event({
            "type":      "alert",
            "level":     payload.level,
            "reason":    payload.reason,
            "latitude":  payload.latitude,
            "longitude": payload.longitude,
        })

    return {"status": "alert_dispatched", "bot_alive": not _bot_is_stale()}


@app.post("/alert/confirm")
async def confirm_safe(data: CodeConfirm):
    global current_alert
    secret = os.getenv("SECRET_CODE", "0000")
    if data.code != secret:
        if current_alert:
            current_alert["attempts"] = current_alert.get("attempts", 0) + 1
        raise HTTPException(status_code=403, detail="Неверный код")
    current_alert = None
    await broadcast_sse("alert_cleared", {"ts": datetime.now().isoformat()})
    return {"status": "confirmed"}


@app.get("/alert/status")
async def alert_status():
    return {"active": current_alert is not None, "alert": current_alert}


# ── SSE стрим ────────────────────────────────────────────────────

@app.get("/events/stream")
async def sse_stream(request: Request):
    """Держит соединение с браузером, шлёт события в реальном времени."""
    queue: asyncio.Queue = asyncio.Queue(maxsize=50)
    sse_subscribers.append(queue)

    async def generate():
        # Начальное состояние
        init_data = {
            "type": "init",
            "data": {
                "points": len(locations_db),
                "bot":    {**bot_state, "stale": _bot_is_stale()},
                "alert":  current_alert,
            }
        }
        yield f"data: {json.dumps(init_data)}\n\n"
        try:
            while True:
                if await request.is_disconnected():
                    break
                try:
                    payload = await asyncio.wait_for(queue.get(), timeout=25.0)
                    yield f"data: {payload}\n\n"
                except asyncio.TimeoutError:
                    yield ": ping\n\n"
        finally:
            if queue in sse_subscribers:
                sse_subscribers.remove(queue)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"}
    )


# ── SOS от iOS приложения ────────────────────────────────────────

class SOSTriggerPayload(BaseModel):
    latitude:  float
    longitude: float
    timestamp: Optional[str] = None
    source:    str = "ios"

@app.post("/sos/trigger")
async def sos_trigger(payload: SOSTriggerPayload, request: Request,
                      _auth: None = Depends(require_api_key)):
    """iOS приложение шлёт сюда SOS — core уведомляет бота."""
    client = request.client.host if request.client else "unknown"
    if not sos_limiter.check(client):
        raise HTTPException(status_code=429, detail="Слишком много SOS-запросов")
    print(f"[CORE] 🆘 SOS от {payload.source}: ({payload.latitude}, {payload.longitude})")
    maps = f"https://maps.google.com/?q={payload.latitude},{payload.longitude}"

    sos_event = {
        "type":      "sos",
        "latitude":  payload.latitude,
        "longitude": payload.longitude,
        "source":    payload.source,
        "maps":      maps,
    }
    await broadcast_sse("sos", sos_event)

    if _bot_is_stale() and registered_chat_id:
        await send_telegram_direct(
            registered_chat_id,
            f"🆘 *SOS из приложения!*\n[Местоположение]({maps})\nИсточник: {payload.source}"
        )
    else:
        await push_bot_event(sos_event)

    return {"status": "sos_received", "bot_alive": not _bot_is_stale()}


# ── Защищённый приём (каскадное шифрование от iOS) ───────────────

class SecureIngestPayload(BaseModel):
    kind: str = "location"          # location | sos | alert
    payload: str                    # base64(cascade packet)

@app.post("/secure/ingest")
async def secure_ingest(body: SecureIngestPayload, request: Request,
                        _auth: None = Depends(require_api_key)):
    """Принимает каскадно-зашифрованный payload от iOS, расшифровывает и
    маршрутизирует как обычный location/sos/alert. Слой прикладного
    шифрования поверх TLS: сервер — единственный, кто может прочитать данные."""
    if not CASCADE_SECRET:
        raise HTTPException(status_code=503, detail="Шифрование не настроено на сервере")
    client = request.client.host if request.client else "unknown"
    if not ingest_limiter.check(client):
        raise HTTPException(status_code=429, detail="Слишком много запросов")
    try:
        raw = crypto.decrypt(base64.b64decode(body.payload), CASCADE_SECRET)
        data = json.loads(raw.decode("utf-8"))
    except Exception:
        # Не раскрываем детали расшифровки (может помочь атакующему).
        raise HTTPException(status_code=400, detail="Не удалось расшифровать payload")

    if body.kind == "location":
        point = {
            "latitude":  float(data["latitude"]),
            "longitude": float(data["longitude"]),
            "timestamp": data.get("timestamp") or datetime.now().isoformat(),
            "source":    data.get("source", "ios_secure"),
        }
        locations_db.append(point)
        await broadcast_sse("location", point)
        return {"status": "received", "kind": "location", "total": len(locations_db)}

    if body.kind == "sos":
        maps = f"https://maps.google.com/?q={data['latitude']},{data['longitude']}"
        sos_event = {"type": "sos", "latitude": data["latitude"],
                     "longitude": data["longitude"], "source": data.get("source", "ios_secure"),
                     "maps": maps}
        await broadcast_sse("sos", sos_event)
        if _bot_is_stale() and registered_chat_id:
            await send_telegram_direct(registered_chat_id,
                                       f"🆘 *SOS (зашифрован)*\n[Местоположение]({maps})")
        else:
            await push_bot_event(sos_event)
        return {"status": "sos_received", "kind": "sos"}

    raise HTTPException(status_code=400, detail=f"Неизвестный kind: {body.kind}")


# ── Анализ подозрений («Мозг» через OpenRouter) ──────────────────

class SuspicionRequest(BaseModel):
    latitude:        float
    longitude:       float
    local_time:      str = ""           # "HH:MM" локального времени
    speed_mps:       Optional[float] = None
    place_type:      str = ""
    near_poi:        str = ""
    route_deviation: str = ""           # если пусто — сервер посчитает сам

@app.post("/analyze/suspicion")
async def analyze_suspicion_endpoint(payload: SuspicionRequest):
    """Оценивает уровень подозрения по контексту через LLM.

    Используется ботом и дашбордом, чтобы «мозг» думал так же,
    как в iOS-приложении. Никогда не падает: при отсутствии ключа
    или сбое LLM возвращает эвристический fallback.
    """
    hour = _hour_of(payload.local_time)
    deviation = payload.route_deviation or _route_deviation_hint(payload.latitude, payload.longitude)

    # Память — до рассуждения: AEGIS должен знать, сколько человек уже стоит
    # на этом месте и знакомо ли оно, ещё до того как выносить вердикт.
    memory = _remember(
        payload.latitude, payload.longitude,
        speed_mps=payload.speed_mps, hour=hour,
        place_type=payload.place_type, route_deviation=deviation,
    )

    ctx = SuspicionContext(
        latitude=payload.latitude,
        longitude=payload.longitude,
        local_time=payload.local_time,
        speed_mps=payload.speed_mps,
        place_type=payload.place_type,
        near_poi=payload.near_poi,
        route_deviation=deviation,
        dwell_minutes=memory["dwell_minutes"],
        place_known=memory["place_known"],
    )
    assessment = await analyze_suspicion(ctx)
    result = assessment.to_dict()

    # Кормим накопительный счётчик: он помнит историю и растёт при
    # устойчивой опасной картине, а не только по мгновенной LLM-оценке.
    counter = suspicion_counter.update(
        hour=hour,
        place_type=payload.place_type,
        route_deviation=ctx.route_deviation,
        speed_mps=payload.speed_mps,
    )
    # Итоговый уровень — максимум из мгновенной LLM-оценки и накопителя.
    # Уровень памяти сюда намеренно не входит: её вклад уже учтён сигналами
    # long_dwell / known_place внутри вердикта, второй раз брать — двойной счёт.
    effective = max(assessment.suspicion, counter["level"])
    result["counter"] = counter
    result["memory"] = memory
    result["effective"] = effective
    print(f"[CORE] 🧠 Подозрение: llm={assessment.suspicion} счётчик={counter['level']} "
          f"→ {effective} ({result['source']}) — {result['reason']}")

    await broadcast_sse("suspicion_level", {
        "level": effective, "counter": counter["level"],
        "reason": assessment.reason or counter["reason"], "rising": counter["rising"],
        "voice": result.get("voice", ""), "action": result.get("action", ""),
    })

    # Порог опроса — по накопленному эффективному уровню.
    if effective >= ASK_THRESHOLD:
        await push_bot_event({
            "type":      "suspicion",
            "suspicion": effective,
            "reason":    assessment.reason or counter["reason"],
            "question":  assessment.question or counter["question"],
            "voice":     result.get("voice", ""),
            "action":    result.get("action", ""),
            "latitude":  payload.latitude,
            "longitude": payload.longitude,
        })
    return result


@app.get("/suspicion/state")
async def suspicion_state():
    """Текущее состояние накопительного счётчика подозрений (для дашборда)."""
    state = suspicion_counter.to_dict()
    # Уровень памяти затухает по часам, а не «по вызову»: если наблюдений
    # давно не было, показываем честно спавший уровень, а не замороженный.
    state["memory"] = aegis_memory.snapshot(now=datetime.now())
    return state


@app.get("/aegis/status")
async def aegis_status():
    """Статус «мозга»: автономный AEGIS + доступность нейросетей.

    Честная картина того, чем ORION сейчас думает: автономный движок
    всегда on; локальная Ollama и облачный OpenRouter — если доступны.
    """
    brain = await backend_status()
    brain["counter"] = suspicion_counter.to_dict()
    brain["memory"] = aegis_memory.snapshot()
    return brain


class HealthRequest(BaseModel):
    steps: int = 0
    distance_km: Optional[float] = None
    weight_kg: Optional[float] = None
    weight_trend_kg: Optional[float] = None
    mood: Optional[int] = None
    stress: Optional[int] = None
    sleep_hours: Optional[float] = None
    supplements: List[str] = []
    note: str = ""
    # Скринеры PHQ-2 / GAD-2: либо [a, b], либо {"mood": a, "interest": b}.
    # Оба формата разбирает aegis._screen_pair — клиенту не нужно угадывать.
    phq2: Optional[Union[List[int], Dict[str, int]]] = None
    gad2: Optional[Union[List[int], Dict[str, int]]] = None
    # Ряды журнала для трендов: {"mood": [...], "sleep_hours": [...]}.
    # Значения — от старых к новым; хватает четырёх точек.
    series: Dict[str, List[Any]] = {}

@app.post("/analyze/health")
async def analyze_health_endpoint(payload: HealthRequest):
    """Мед-анализ состояния через LLM. Не падает: при отсутствии ключа
    или сбое возвращает fallback. Не является медицинской консультацией."""
    assessment = await analyze_health(payload.model_dump())
    result = assessment.to_dict()
    print(f"[CORE] ❤️ Состояние: {result['score']}/100 ({result['source']})")
    return result
