"""Self-contained tests for the AEGIS autonomous brain.

Run: python tests/test_aegis.py   (exits non-zero on failure)
No pytest dependency; no network — AEGIS is fully offline.
"""
import asyncio
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Не ходим в сеть: openrouter без ключа мгновенно отдаёт None → AEGIS.
os.environ["LLM_BACKEND"] = "openrouter"
os.environ["OPENROUTER_API_KEY"] = ""

from core import aegis  # noqa: E402
from core.llm import SuspicionContext, analyze_suspicion, analyze_health, backend_status  # noqa: E402

FAIL = 0


def check(name, cond):
    global FAIL
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAIL += 1


# ── Ситуация: опасное сочетание ночь+промзона+неподвижность ──────────
v = aegis.assess_situation(hour=3, place_type="промзона склад",
                           route_deviation="далеко (12 км)", speed_mps=0.1)
check("danger combo → suspicion >= 75", v.suspicion >= 75)
check("danger combo → should_ask", v.should_ask)
check("danger combo → action escalates", v.action in ("prepare_sos", "ask_user"))
check("danger combo → voice non-empty", len(v.voice) > 10)
check("danger combo → signals collected", len(v.signals) >= 3)
check("source is aegis", v.source == "aegis")

# ── Ситуация: день в безопасном месте ───────────────────────────────
v = aegis.assess_situation(hour=14, place_type="набережная парк", speed_mps=1.5)
check("safe day → suspicion <= 25", v.suspicion <= 25)
check("safe day → no ask", not v.should_ask)
check("safe day → action calm", v.action in ("observe", "none", "monitor"))

# ── Монотонность: ночь опаснее дня при прочих равных ────────────────
day = aegis.assess_situation(hour=14, place_type="промзона").suspicion
night = aegis.assess_situation(hour=3, place_type="промзона").suspicion
check("night > day (same place)", night > day)

# ── Здоровье ────────────────────────────────────────────────────────
h = aegis.assess_health({"steps": 12000, "sleep_hours": 8, "mood": 5, "stress": 1})
check("good health → score >= 70", h["score"] >= 70)
h = aegis.assess_health({"steps": 500, "sleep_hours": 4, "mood": 1, "stress": 5,
                         "weight_trend_kg": -5})
check("bad health → score <= 40", h["score"] <= 40)
check("bad health → has summary", len(h["summary"]) > 0)
h = aegis.assess_health({})
check("empty health → still answers", 0 <= h["score"] <= 100)


# ── Интеграция через llm.py (без сети) ──────────────────────────────
async def _integration():
    ctx = SuspicionContext(latitude=55.7, longitude=37.6, local_time="03:12",
                           speed_mps=0.0, place_type="промзона",
                           route_deviation="далеко (10 км)")
    a = await analyze_suspicion(ctx)
    check("llm.py falls to aegis", a.source == "aegis")
    check("llm.py verdict has voice", bool(a.to_dict().get("voice")))
    check("llm.py high suspicion", a.suspicion >= 75)

    ha = await analyze_health({"steps": 300, "sleep_hours": 3, "stress": 5})
    check("health via llm.py → aegis", ha.source == "aegis")
    check("health via llm.py scored", 0 <= ha.score <= 100)

    st = await backend_status()
    check("backend_status callsign", st["callsign"] == aegis.CALLSIGN)
    check("backend_status active=aegis", st["active"] == "aegis")
    check("backend_status not neural", st["neural_augmented"] is False)

asyncio.run(_integration())

print()
if FAIL:
    print(f"{FAIL} test(s) FAILED")
    sys.exit(1)
print("All AEGIS tests passed.")
