"""Self-contained tests for AEGIS v2: память, скринеры, тренды.

Run: python tests/test_aegis_memory.py   (exits non-zero on failure)
No pytest dependency; no network — всё считается локально.

Время всюду задаётся явно (`now=...`): тест не должен зависеть от того,
как быстро он выполняется, а память как раз меряет минуты между наблюдениями.
"""
import asyncio
import os
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

# Windows-консоль по умолчанию cp1251 — русский текст в выводе её роняет.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Свой каталог данных: сквозной тест поднимает настоящий app, а тот заводит
# Store и пишет память на диск — реальные данные трогать нельзя.
os.environ["ORION_DATA_DIR"] = tempfile.mkdtemp(prefix="orion_aegis_test_")
os.environ["LLM_BACKEND"] = "openrouter"
os.environ["OPENROUTER_API_KEY"] = ""
# Ключ задаём сами, а не полагаемся на .env: /location/update закрыт
# require_api_key, и тест не должен зависеть от того, что лежит у разработчика.
API_KEY = "test-key-aegis"
os.environ["ORION_API_KEY"] = API_KEY
AUTH = {"X-Orion-Key": API_KEY}

from core import aegis  # noqa: E402
from core.aegis_memory import (  # noqa: E402
    AegisMemory, BASELINE, HALF_LIFE_MIN, MAX_PLACES, cell_of,
)

FAIL = 0
T0 = datetime(2026, 7, 20, 12, 0, 0)


def check(name, cond):
    global FAIL
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAIL += 1


# ── Ячейки ──────────────────────────────────────────────────────────
check("cell quantizes ~110 m", cell_of(55.7512, 37.6184) == cell_of(55.7514, 37.6183))
check("cell separates distant points", cell_of(55.751, 37.618) != cell_of(55.760, 37.618))
check("cell tolerates None", cell_of(None, 37.6) is None)
check("cell tolerates NaN", cell_of(float("nan"), 37.6) is None)


# ── Затухание идёт по времени, а не «по вызову» ─────────────────────
m = AegisMemory()
m.observe(instant=90, lat=55.75, lon=37.61, now=T0)
peaked = m.level
check("rise moves toward instant", peaked > BASELINE + 20)

half = m.level_at(T0 + timedelta(minutes=HALF_LIFE_MIN))
check("half-life halves the gap to baseline",
      abs(half - (BASELINE + (peaked - BASELINE) / 2)) < 1.5)
check("level_at does not mutate", m.level == peaked)
check("level_at leaves last_update alone", m.last_update == T0.isoformat())
check("decay after a day ≈ baseline", m.level_at(T0 + timedelta(days=1)) <= BASELINE + 1)

m.decay_to(T0 + timedelta(minutes=HALF_LIFE_MIN))
check("decay_to does mutate", m.level < peaked)
check("decay_to moves the clock", m.last_update == (T0 + timedelta(minutes=HALF_LIFE_MIN)).isoformat())

# Долгое молчание: v1-счётчик остался бы высоким, память — нет.
quiet = AegisMemory()
quiet.observe(instant=100, lat=55.75, lon=37.61, now=T0)
quiet.observe(instant=20, lat=55.75, lon=37.61, now=T0 + timedelta(hours=6))
check("six quiet hours bring level home", quiet.level <= BASELINE + 1)


# ── Dwell ───────────────────────────────────────────────────────────
d = AegisMemory()
for i in range(7):                        # 7 наблюдений по 5 минут = 30 мин
    snap = d.observe(instant=30, lat=55.75, lon=37.61, speed_mps=0.0,
                     now=T0 + timedelta(minutes=5 * i))
check("dwell accumulates while standing", 29 <= snap["dwell_minutes"] <= 31)

snap = d.observe(instant=30, lat=55.80, lon=37.61, speed_mps=0.0,
                 now=T0 + timedelta(minutes=35))
check("dwell resets on cell change", snap["dwell_minutes"] == 0)

d2 = AegisMemory()
d2.observe(instant=30, lat=55.75, lon=37.61, speed_mps=0.0, now=T0)
d2.observe(instant=30, lat=55.75, lon=37.61, speed_mps=0.0, now=T0 + timedelta(minutes=5))
snap = d2.observe(instant=30, lat=55.75, lon=37.61, speed_mps=4.0,
                  now=T0 + timedelta(minutes=10))
check("dwell resets when moving fast", snap["dwell_minutes"] == 0)

d3 = AegisMemory()
d3.observe(instant=30, lat=55.75, lon=37.61, speed_mps=0.0, now=T0)
snap = d3.observe(instant=30, lat=55.75, lon=37.61, speed_mps=0.0,
                  now=T0 + timedelta(hours=3))
check("dwell resets after a long gap", snap["dwell_minutes"] == 0)


# ── Привычные места ─────────────────────────────────────────────────
h = AegisMemory()
snap = h.observe(instant=30, lat=55.75, lon=37.61, now=T0)
check("first sight says nothing about the place", snap["place_known"] is None)

# Три визита в три разных дня: уходим и возвращаемся, иначе это один визит.
for day in range(3):
    base = T0 + timedelta(days=day)
    h.observe(instant=30, lat=55.75, lon=37.61, now=base)
    h.observe(instant=30, lat=55.90, lon=37.61, now=base + timedelta(hours=2))
snap = h.observe(instant=30, lat=55.75, lon=37.61, now=T0 + timedelta(days=3))
check("place becomes habitual", snap["place_known"] is True)
check("habitual place counted", snap["habitual_places"] >= 1)

snap = h.observe(instant=30, lat=54.10, lon=38.90, now=T0 + timedelta(days=3, hours=1))
check("strange place flagged once memory has a baseline", snap["place_known"] is False)

check("staying put is one visit, not many",
      h.places[cell_of(55.90, 37.61)].visits <= 3)


# ── Вытеснение ──────────────────────────────────────────────────────
e = AegisMemory()
for day in range(3):                       # делаем одно место привычным
    base = T0 + timedelta(days=day)
    e.observe(instant=30, lat=55.75, lon=37.61, now=base)
    e.observe(instant=30, lat=55.90, lon=37.61, now=base + timedelta(hours=2))
home = cell_of(55.75, 37.61)
for i in range(MAX_PLACES + 50):           # заливаем память случайными точками
    e.observe(instant=30, lat=50.0 + i * 0.01, lon=30.0,
              now=T0 + timedelta(days=4, minutes=i))
check("memory stays bounded", len(e.places) <= MAX_PLACES)
check("habitual places evicted last", home in e.places)


# ── Сериализация ────────────────────────────────────────────────────
raw = h.to_dict()
restored = AegisMemory.from_dict(raw)
check("roundtrip keeps places", len(restored.places) == len(h.places))
check("roundtrip keeps habitual count", restored.habitual_count == h.habitual_count)
check("roundtrip keeps dwell cell", restored.dwell_cell == h.dwell_cell)
check("from_dict tolerates garbage", AegisMemory.from_dict(None).level == BASELINE)
check("from_dict skips cell-less places",
      len(AegisMemory.from_dict({"places": [{"visits": 5}]}).places) == 0)


# ── Новые сигналы в вердикте ────────────────────────────────────────
plain = aegis.assess_situation(hour=14, place_type="")
withmem = aegis.assess_situation(hour=14, place_type="", dwell_minutes=50)
check("long dwell raises suspicion", withmem.suspicion > plain.suspicion)
check("long dwell shows up as a signal",
      any(s.code == "long_dwell" for s in withmem.signals))

known = aegis.assess_situation(hour=3, place_type="", place_known=True)
unknown = aegis.assess_situation(hour=3, place_type="", place_known=False)
check("known place calms", known.suspicion < unknown.suspicion)
check("known place shows up as a signal", any(s.code == "known_place" for s in known.signals))
check("unknown place shows up as a signal", any(s.code == "unknown_place" for s in unknown.signals))

# Без памяти движок обязан вести себя ровно как v1.
check("no memory → v1 behaviour",
      aegis.assess_situation(hour=3, place_type="промзона").suspicion
      == aegis.assess_situation(hour=3, place_type="промзона",
                                dwell_minutes=None, place_known=None).suspicion)

# Сочетание: ночь + незнакомое место + долгий dwell.
combo = aegis.assess_situation(hour=3, place_type="", speed_mps=0.0,
                               dwell_minutes=60, place_known=False)
check("night + unknown + dwell escalates", combo.suspicion >= 75)
check("compound reason is spelled out", "незнаком" in combo.reason or "незнаком" in combo.voice)


# ── Скринеры PHQ-2 / GAD-2 ──────────────────────────────────────────
check("no screener → nothing", aegis.screen_mental({}) == {})
check("list format accepted", aegis.screen_mental({"phq2": [3, 3]})["phq2"]["score"] == 6)
check("dict format accepted",
      aegis.screen_mental({"phq2": {"interest": 3, "mood": 3}})["phq2"]["score"] == 6)
check("both formats agree",
      aegis.screen_mental({"gad2": [1, 2]})["gad2"]["score"]
      == aegis.screen_mental({"gad2": {"nervous": 1, "worry": 2}})["gad2"]["score"])
check("cutoff at 3", aegis.screen_mental({"phq2": [2, 1]})["phq2"]["positive"] is True)
check("below cutoff is negative", aegis.screen_mental({"phq2": [1, 1]})["phq2"]["positive"] is False)
check("out-of-range answers clamped", aegis.screen_mental({"phq2": [9, 9]})["phq2"]["score"] == 6)
check("half-filled screener ignored", aegis.screen_mental({"phq2": [2]}) == {})
check("junk screener ignored", aegis.screen_mental({"phq2": "да"}) == {})

positive = aegis.assess_health({"phq2": [3, 3], "gad2": [3, 3]})
neutral = aegis.assess_health({"phq2": [0, 0], "gad2": [0, 0]})
check("positive screeners lower the score", positive["score"] < neutral["score"])
check("positive screener becomes a flag", any("PHQ2" in f for f in positive["flags"]))
check("positive screener adds advice", len(positive["recommendations"]) > 0)
check("screens ride along in the verdict", "phq2" in positive["screens"])

# Валидированный опрос заменяет разовую отметку, а не складывается с ней:
# иначе один и тот же признак штрафовался бы дважды.
both = aegis.assess_health({"mood": 1, "stress": 5, "phq2": [3, 3], "gad2": [3, 3]})
screen_only = aegis.assess_health({"phq2": [3, 3], "gad2": [3, 3]})
check("screener supersedes the single-item score", both["score"] == screen_only["score"])
check("no double flag for mood", not any("сниженное настроение" in f for f in both["flags"]))
check("single item still counts without a screener",
      aegis.assess_health({"mood": 1})["score"] < aegis.assess_health({})["score"])
check("bad picture does not saturate at zero",
      aegis.assess_health({"steps": 900, "sleep_hours": 4, "phq2": [3, 3],
                           "gad2": [3, 3], "series": {"mood": [5, 4, 3, 2]}})["score"] > 0)


# ── Тренды журнала ──────────────────────────────────────────────────
check("three points are not a trend", aegis.analyze_trends({"mood": [5, 4, 3]}) == {})
check("flat series is not worsening",
      aegis.analyze_trends({"mood": [3, 3, 3, 3]})["mood"]["worsening"] is False)

falling = aegis.analyze_trends({"mood": [5, 4, 3, 2]})["mood"]
check("falling mood is worsening", falling["worsening"] is True)
check("falling mood reads as хуже", falling["direction"] == "хуже")
check("slope sign is right", falling["slope"] < 0)

rising_stress = aegis.analyze_trends({"stress": [1, 2, 3, 5]})["stress"]
check("rising stress is worsening", rising_stress["worsening"] is True)
check("rising mood is improving",
      aegis.analyze_trends({"mood": [2, 3, 4, 5]})["mood"]["direction"] == "лучше")
check("junk values skipped, not fatal",
      aegis.analyze_trends({"mood": [5, None, 4, 3, 2]})["mood"]["worsening"] is True)

nested = aegis.assess_health({"series": {"mood": [5, 4, 3, 2]}})
flat = aegis.assess_health({"mood_series": [5, 4, 3, 2]})
check("nested and flat series read the same", nested["score"] == flat["score"])
check("worsening trend lowers the score", nested["score"] < aegis.assess_health({})["score"])
check("worsening trend becomes a flag", any("ухудшается" in f for f in nested["flags"]))
check("trends ride along in the verdict", "mood" in nested["trends"])
check("empty health still answers", 0 <= aegis.assess_health({})["score"] <= 100)


# ── Сквозная проводка через сервер ──────────────────────────────────

async def _wiring():
    import httpx
    from core.main import app, aegis_memory

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as c:
        # Поток координат — единственный регулярный пульс: он и учит память.
        for _ in range(4):
            r = await c.post("/location/update", headers=AUTH,
                             json={"latitude": 55.7512, "longitude": 37.6184,
                                   "speed_mps": 0.0, "source": "test"})
        check("location update ok", r.status_code == 200)
        check("location feeds memory", aegis_memory.places.get(cell_of(55.7512, 37.6184)) is not None)

        r = await c.get("/suspicion/state")
        state = r.json()
        check("/suspicion/state exposes memory", "memory" in state)
        check("/suspicion/state keeps the old counter", "level" in state)
        # Читающий эндпоинт не имеет права двигать часы памяти: иначе один
        # опрос дашборда обнулил бы разрыв и dwell перестал бы копиться.
        before = aegis_memory.last_update
        await c.get("/suspicion/state")
        check("reading state does not touch memory", aegis_memory.last_update == before)

        r = await c.get("/aegis/status")
        check("/aegis/status exposes memory", "memory" in r.json())

        r = await c.post("/analyze/suspicion",
                         json={"latitude": 55.7512, "longitude": 37.6184,
                               "local_time": "03:20", "speed_mps": 0.0,
                               "place_type": "промзона"})
        body = r.json()
        check("/analyze/suspicion ok", r.status_code == 200)
        check("verdict carries memory", "memory" in body)
        check("verdict still carries counter", "counter" in body)
        check("night industrial still escalates", body["effective"] >= 60)

        r = await c.post("/analyze/health",
                         json={"steps": 900, "sleep_hours": 4, "stress": 5,
                               "phq2": [3, 3], "gad2": {"nervous": 3, "worry": 3},
                               "series": {"mood": [5, 4, 3, 2]}})
        body = r.json()
        check("/analyze/health ok", r.status_code == 200)
        check("health carries screens", body.get("screens", {}).get("phq2", {}).get("positive") is True)
        check("health carries trends", body.get("trends", {}).get("mood", {}).get("worsening") is True)
        check("health still carries score", 0 <= body["score"] <= 100)

        # Старый клиент без новых полей обязан работать как раньше.
        r = await c.post("/analyze/health", json={"steps": 5000})
        check("legacy health payload still accepted", r.status_code == 200)
        check("legacy payload → empty screens", r.json()["screens"] == {})

    # Память должна пережить перезапуск процесса (сон Render).
    from core.aegis_memory import AegisMemory as _Mem
    from core.main import store, AEGIS_MEMORY_KEY
    store.save_brain(AEGIS_MEMORY_KEY, aegis_memory.to_dict())
    revived = _Mem.from_dict(store.get_brain(AEGIS_MEMORY_KEY))
    check("memory survives a restart", len(revived.places) == len(aegis_memory.places))

asyncio.run(_wiring())


print()
if FAIL:
    print(f"{FAIL} test(s) FAILED")
    sys.exit(1)
print("All AEGIS memory/screener/trend tests passed.")
