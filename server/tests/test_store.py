"""Тесты персистентного хранилища и истории перемещений.

Запуск: python tests/test_store.py   (ненулевой код возврата при провале)
Сети не требует. Пишет во временный каталог, реальные данные не трогает.
"""
import asyncio
import os
import sys
import tempfile
from pathlib import Path

# Windows-консоль по умолчанию cp1251 — русский текст в выводе её роняет.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Изолируем данные теста и включаем ключ, чтобы проверить и авторизацию.
_TMP = tempfile.mkdtemp(prefix="orion_store_test_")
os.environ["ORION_DATA_DIR"] = _TMP
os.environ["ORION_API_KEY"] = "test-key-123"
os.environ["ORION_CASCADE_SECRET"] = "test-cascade-secret"
os.environ["LLM_BACKEND"] = "openrouter"
os.environ["OPENROUTER_API_KEY"] = ""

from core.store import Store              # noqa: E402

FAIL = 0


def check(name, cond):
    global FAIL
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAIL += 1


# ── Трек и last_location ─────────────────────────────────────────────
s = Store(filename="unit.json")
s.reset()
s.add_track_point("phone-1", {"latitude": 55.75, "longitude": 37.61,
                              "timestamp": "2026-07-03T10:05:00+00:00",
                              "source": "ios_orion"})
s.add_track_point("phone-1", {"latitude": 55.76, "longitude": 37.62,
                              "timestamp": "2026-07-03T10:10:00+00:00",
                              "source": "ios_orion"})
check("трек накопился", len(s.track("phone-1")) == 2)
check("last_location = последняя точка",
      s.devices()["phone-1"]["last_location"]["latitude"] == 55.76)

# ── Персистентность: новый Store читает тот же файл ──────────────────
s2 = Store(filename="unit.json")
check("трек переживает перезапуск", len(s2.track("phone-1")) == 2)
check("устройство переживает перезапуск", "phone-1" in s2.devices())

# ── Память «мозга» тоже на диске ─────────────────────────────────────
s2.save_brain("aegis_memory", {"level": 42})
check("память мозга читается", Store(filename="unit.json")
      .get_brain("aegis_memory") == {"level": 42})
check("неизвестный ключ → пустой словарь", s2.get_brain("нет-такого") == {})

# ── Фильтры трека на уровне стора ────────────────────────────────────
s5 = Store(filename="filters.json")
s5.reset()
for ts, place in [("2026-08-03T09:00:00+00:00", "Дом"),
                  ("2026-08-04T09:15:00Z",      "Дом"),
                  ("2026-08-04T13:40:00",       "Кофейня на Мира")]:
    s5.add_track_point("d", {"latitude": 56.0, "longitude": 92.8,
                             "timestamp": ts, "place": place})
check("границы из одной даты = день целиком",
      len(s5.track_filtered(since="2026-08-04", until="2026-08-04")) == 2)
check("фильтр по времени", len(s5.track_filtered(
      since="2026-08-04T13:00:00", until="2026-08-04T14:00:00")) == 1)
check("фильтр по месту без учёта регистра",
      len(s5.track_filtered(place="дом")) == 2)
check("список мест собран", s5.track_places() == ["Дом", "Кофейня на Мира"])
check("limit=0 отдаёт всё", len(s5.track_filtered(limit=0)) == 3)

# ── Подрезка трека при переполнении ──────────────────────────────────
from core import store as store_mod  # noqa: E402
s3 = Store(filename="cap.json")
s3.reset()
cap = store_mod.MAX_TRACK_POINTS
for i in range(cap + 50):
    s3.add_track_point("d", {"latitude": 1.0, "longitude": 2.0,
                             "timestamp": f"2026-07-01T00:00:{i % 60:02d}.{i:06d}+00:00"})
check("трек подрезан до лимита", len(s3.track("d", limit=cap + 100)) == cap)

# ── Битый файл не роняет сервер ──────────────────────────────────────
(Path(_TMP) / "broken.json").write_text("{не json", encoding="utf-8")
s4 = Store(filename="broken.json")
check("битый файл → пустое состояние", s4.devices() == {})

# ── HTTP-слой: /location/update пишет на диск, /track отдаёт с фильтрами ─
try:
    import httpx
    from core.main import app

    async def http_checks():
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://t") as c:
            key = {"X-Orion-Key": "test-key-123"}

            r = await c.get("/track")
            check("/track без ключа → 401", r.status_code == 401)

            walk = [
                ("2026-08-03T09:00:00+00:00", "Дом"),
                ("2026-08-04T09:15:00+00:00", "Дом"),
                ("2026-08-04T13:40:00+00:00", "Кофейня на Мира"),
                ("2026-08-04T21:05:00+00:00", "Дом"),
            ]
            for ts, place in walk:
                r = await c.post("/location/update", headers=key, json={
                    "latitude": 56.01, "longitude": 92.87, "timestamp": ts,
                    "source": "ios_orion", "device_id": "owner-http", "place": place,
                })
                check(f"/location/update {ts[11:16]} 200", r.status_code == 200)

            r = await c.get("/track?device_id=owner-http", headers=key)
            check("/track вернул весь трек", r.json()["total"] == 4)
            check("/track собрал места", "Кофейня на Мира" in r.json()["places"])

            r = await c.get("/track?device_id=owner-http&since=2026-08-04&until=2026-08-04",
                            headers=key)
            check("/track фильтр по дате", r.json()["total"] == 3)

            r = await c.get("/track?device_id=owner-http&since=2026-08-04T13:00:00"
                            "&until=2026-08-04T14:00:00", headers=key)
            pts = r.json()["points"]
            check("/track фильтр по времени", len(pts) == 1 and pts[0]["place"] == "Кофейня на Мира")

            r = await c.get("/track?device_id=owner-http&place=дом", headers=key)
            check("/track фильтр по месту", r.json()["total"] == 3)

            r = await c.get("/track/days?device_id=owner-http", headers=key)
            days = {d["date"]: d["points"] for d in r.json()["days"]}
            check("/track/days считает точки по дням",
                  days == {"2026-08-03": 1, "2026-08-04": 3})

            # Неизвестный kind в шифрованном канале — 400, а не 500.
            r = await c.post("/secure/ingest",
                             json={"kind": "не-бывает", "payload": "AAAA"}, headers=key)
            check("/secure/ingest неизвестный kind → 400", r.status_code == 400)

            # ── Дашборд: тот же фильтр, но в query-параметрах и без ключа.
            #    Страница открыта, поэтому фильтрует сервер, а не браузер.
            r = await c.get("/")
            check("дашборд открывается без ключа", r.status_code == 200)
            check("дашборд показывает панель истории", "История перемещений" in r.text)
            check("дашборд подставил дни в фильтр", "2026-08-03" in r.text)
            check("дашборд подставил места", "Кофейня на Мира" in r.text)

            r = await c.get("/?day=2026-08-04&from_time=13:00&to_time=14:00")
            check("дашборд: фильтр по дате и времени",
                  "Кофейня на Мира" in r.text and "Точек: <strong>1</strong>" in r.text)

            r = await c.get("/?place=кофейня")
            check("дашборд: фильтр по месту", "Точек: <strong>1</strong>" in r.text)

            r = await c.get("/?day=2026-01-01")
            check("дашборд: пустой период не ломает страницу",
                  r.status_code == 200 and "точек не записано" in r.text)

    asyncio.run(http_checks())
except ImportError as e:
    print(f"SKIP HTTP-проверки (нет зависимости: {e})")

print()
if FAIL:
    print(f"❌ Провалено проверок: {FAIL}")
    sys.exit(1)
print("✅ Все проверки хранилища пройдены")
