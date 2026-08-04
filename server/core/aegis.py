"""
╔══════════════════════════════════════════════════════════════════╗
║  A.E.G.I.S.  —  «мозг» O.R.I.O.N. (Adaptive Emergency Guardian    ║
║                 Intelligence System)                              ║
║  Автономный рассуждающий движок, работающий БЕЗ нейросети и без   ║
║  интернета. Нейросеть (локальная Ollama / облачный OpenRouter) —  ║
║  только необязательное усиление, а не условие работы.            ║
╚══════════════════════════════════════════════════════════════════╝

Зачем это нужно
───────────────
Раньше «мозг» ORION целиком зависел от внешней LLM: нет ключа OpenRouter или
не поднята Ollama — и система молча сваливалась в примитивный эвристический
fallback из трёх правил. На машине пользователя ни одна нейронка не
подключалась, поэтому ИИ фактически «слеп».

A.E.G.I.S. переворачивает логику: базовый интеллект живёт локально и работает
ВСЕГДА. Он не просто складывает баллы, а рассуждает — ищет опасные СОЧЕТАНИЯ
признаков (глубокая ночь + промзона + неподвижность = совсем другой вес, чем
каждый признак по отдельности), формулирует вывод «голосом» ассистента и
предлагает конкретное действие. Если рядом есть настоящая нейросеть — AEGIS
задействует её как «второе мнение», но никогда от неё не зависит.

Дизайн
──────
• Никаких сетевых вызовов в этом модуле — только чистая логика. За внешние
  модели по-прежнему отвечает llm.py; он вызывает AEGIS, а не наоборот.
• Переиспользуем уже оттестированные скореры из suspicion.py (время, зона,
  отклонение, скорость), а поверх добавляем слой рассуждений о сочетаниях.
• Персона (позывной, тон) вынесена в константы, чтобы её было легко менять.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from core.suspicion import (
    _hour_score,
    _zone_score,
    _deviation_score,
    _speed_score,
    _clamp,
    ASK_THRESHOLD,
)

# ── Персона ассистента ───────────────────────────────────────────────
# «ИИ в духе Старка»: собранный, немногословный, на «ты», без паники.
CALLSIGN = "AEGIS"
PERSONA_TAGLINE = "Adaptive Emergency Guardian Intelligence System"


@dataclass
class Signal:
    """Один распознанный фактор с вкладом и человекочитаемой формулировкой."""
    code: str            # машинный код фактора: "night", "industrial", ...
    label: str           # что показать человеку: «глубокая ночь»
    weight: int          # вклад в подозрение (может быть отрицательным)

    def to_dict(self) -> dict:
        return {"code": self.code, "label": self.label, "weight": self.weight}


@dataclass
class Verdict:
    """Итог рассуждения AEGIS по обстановке."""
    suspicion: int              # 0..100 — мгновенная оценка
    reason: str                 # короткая причина (для дашборда/логов)
    voice: str                  # реплика «голосом» ассистента
    action: str                 # рекомендованное действие: monitor|ask|prepare_sos
    should_ask: bool
    question: str
    signals: list = field(default_factory=list)
    confidence: int = 0         # 0..100 — насколько AEGIS уверен в выводе
    source: str = "aegis"       # aegis | aegis+llm

    def to_dict(self) -> dict:
        return {
            "suspicion": self.suspicion,
            "reason": self.reason,
            "voice": self.voice,
            "action": self.action,
            "should_ask": self.should_ask,
            "question": self.question,
            "signals": [s.to_dict() for s in self.signals],
            "confidence": self.confidence,
            "source": self.source,
            "callsign": CALLSIGN,
        }


# ── Ядро: рассуждение об обстановке ─────────────────────────────────

def _collect_signals(
    *,
    hour: Optional[int],
    place_type: str,
    route_deviation: str,
    speed_mps: Optional[float],
    dwell_minutes: Optional[float] = None,
    place_known: Optional[bool] = None,
) -> list:
    """Разложить обстановку на именованные факторы с их вкладом.

    `dwell_minutes` и `place_known` приходят из AegisMemory и оба
    необязательны: без памяти (первый запуск, нет координат) движок ведёт
    себя ровно как v1 — сигналы просто не появляются.
    """
    signals: list = []

    hs = _hour_score(hour)
    if hs >= 25:
        signals.append(Signal("night", "глубокая ночь", hs))
    elif hs > 0:
        signals.append(Signal("dusk", "вечер / раннее утро", hs))

    zs = _zone_score(place_type)
    if zs >= 20:
        signals.append(Signal("industrial", "нежилая / промзона", zs))
    elif zs > 0:
        signals.append(Signal("odd_place", "нетипичное место", zs))
    elif zs < 0:
        signals.append(Signal("safe_place", "безопасное место", zs))

    ds = _deviation_score(route_deviation)
    if ds >= 25:
        signals.append(Signal("far_deviation", "далеко от привычных мест", ds))
    elif ds > 0:
        signals.append(Signal("mild_deviation", "лёгкое отклонение маршрута", ds))

    ss = _speed_score(speed_mps, hour)
    if ss > 0:
        signals.append(Signal("motionless", "подозрительно неподвижен", ss))
    elif ss < 0:
        signals.append(Signal("moving", "уверенно движется", ss))

    # Память: сколько человек уже стоит на одном месте. Мгновенная
    # неподвижность (motionless) и сорок минут в одной точке — разные вещи.
    if dwell_minutes is not None:
        if dwell_minutes >= 45:
            signals.append(Signal("long_dwell", f"не двигается {int(dwell_minutes)} мин", 18))
        elif dwell_minutes >= 20:
            signals.append(Signal("long_dwell", f"не двигается {int(dwell_minutes)} мин", 10))

    # Память: узнаёт ли AEGIS это место. None — сказать пока нечего.
    if place_known is True:
        signals.append(Signal("known_place", "привычное место", -18))
    elif place_known is False:
        signals.append(Signal("unknown_place", "незнакомое место", 8))

    return signals


def _compound_bonus(signals: list) -> tuple[int, Optional[str]]:
    """Слой рассуждений: опасны не факторы по отдельности, а их СОЧЕТАНИЯ.

    Возвращает добавку к подозрению и (опционально) короткий вывод о том,
    какое именно сочетание сработало — это то, что отличает «мозг» от
    простого сумматора баллов.
    """
    codes = {s.code for s in signals}

    # Порядок правил = порядок убывания тревожности: возвращаем первое
    # совпавшее, поэтому сочетания с памятью стоят выше одноимённых без неё.
    if {"night", "unknown_place", "long_dwell"} <= codes:
        return 24, "ночью надолго застрял в незнакомом месте"
    # Классический тревожный паттерн: ночь + нежилая зона + неподвижность.
    if {"night", "industrial", "motionless"} <= codes:
        return 20, "ночь, нежилая зона и полная неподвижность вместе"
    if {"far_deviation", "long_dwell"} <= codes:
        return 16, "давно не двигается вдали от привычных мест"
    if {"industrial", "long_dwell"} <= codes:
        return 14, "давно стоит в нежилой зоне"
    if {"night", "industrial"} <= codes:
        return 12, "ночь в нежилой зоне"
    if {"night", "far_deviation"} <= codes:
        return 12, "ночью далеко от привычных мест"
    if {"industrial", "motionless"} <= codes:
        return 10, "долго стоит в нежилой зоне"
    if {"night", "motionless"} <= codes:
        return 8, "ночью долго не двигается"
    return 0, None


def _confidence(signals: list, compound: bool) -> int:
    """Насколько AEGIS уверен: больше согласованных факторов → выше уверенность."""
    risky = [s for s in signals if s.weight > 0]
    conf = 40 + 12 * len(risky)
    if compound:
        conf += 15
    return _clamp(conf, 0, 95)


def _voice(suspicion: int, reason: str, compound_note: Optional[str]) -> tuple[str, str]:
    """Сформировать реплику ассистента и рекомендованное действие.

    Тон — спокойный и деловой: не пугаем, но и не преуменьшаем.
    """
    focus = compound_note or reason
    if suspicion >= 80:
        return (
            f"Обстановка тревожная: {focus}. Держу связь наготове и готовлю SOS — "
            f"скажи одно слово, и я подниму тревогу.",
            "prepare_sos",
        )
    if suspicion >= ASK_THRESHOLD:
        return (
            f"Мне не нравится картина: {focus}. Проверю, всё ли в порядке.",
            "ask",
        )
    if suspicion >= 35:
        return (
            f"Приглядываю: {focus}. Пока без повода для тревоги.",
            "monitor",
        )
    return (
        "Всё спокойно. Я на связи и слежу за обстановкой.",
        "monitor",
    )


def assess_situation(
    *,
    hour: Optional[int],
    place_type: str = "",
    route_deviation: str = "",
    speed_mps: Optional[float] = None,
    dwell_minutes: Optional[float] = None,
    place_known: Optional[bool] = None,
) -> Verdict:
    """Главная точка входа автономного мозга: оценить обстановку.

    Работает всегда, без сети и без нейросети. Возвращает не только число,
    но и рассуждение: какие факторы сработали, какое сочетание опасно,
    что ассистент собирается делать.

    `dwell_minutes` / `place_known` — необязательный срез из AegisMemory
    (core/aegis_memory.py). Без него оценка остаётся такой же, как в v1.
    """
    signals = _collect_signals(
        hour=hour, place_type=place_type,
        route_deviation=route_deviation, speed_mps=speed_mps,
        dwell_minutes=dwell_minutes, place_known=place_known,
    )
    base = 20
    raw = base + sum(s.weight for s in signals)

    bonus, compound_note = _compound_bonus(signals)
    raw += bonus
    suspicion = _clamp(raw)

    # Причина — из самых весомых факторов (как в suspicion.py), но приоритет
    # отдаём выявленному опасному сочетанию, если оно есть.
    risky = sorted((s for s in signals if s.weight > 0), key=lambda s: -s.weight)
    if compound_note:
        reason = compound_note
    elif risky:
        reason = ", ".join(s.label for s in risky[:3])
    else:
        reason = "обычная обстановка"

    voice, action = _voice(suspicion, reason, compound_note)
    should_ask = suspicion >= ASK_THRESHOLD
    question = "Всё ли с тобой хорошо? Ответь, и я успокоюсь." if should_ask else ""

    return Verdict(
        suspicion=suspicion,
        reason=reason,
        voice=voice,
        action=action,
        should_ask=should_ask,
        question=question,
        signals=signals,
        confidence=_confidence(signals, compound_note is not None),
        source="aegis",
    )


# ── Скрининг состояния: PHQ-2 / GAD-2 ───────────────────────────────
#
# Это валидированные двухвопросные скринеры, а не диагноз: PHQ-2 отсеивает
# депрессивный эпизод, GAD-2 — генерализованную тревогу. Каждый пункт
# оценивается 0..3 («совсем нет» … «почти каждый день»), сумма 0..6,
# общепринятая точка отсечения — 3. Положительный результат означает ровно
# одно: есть повод пройти полную шкалу (PHQ-9 / GAD-7) со специалистом.

SCREEN_CUTOFF = 3

PHQ2_ITEMS = ("interest", "mood")
GAD2_ITEMS = ("nervous", "worry")

PHQ2_QUESTIONS = (
    "Как часто за последние две недели тебя беспокоило: мало интереса или удовольствия от дел?",
    "Как часто за последние две недели тебя беспокоило: подавленность, тоска или безнадёжность?",
)
GAD2_QUESTIONS = (
    "Как часто за последние две недели ты чувствовал нервозность, тревогу или взвинченность?",
    "Как часто за последние две недели ты не мог перестать волноваться или контролировать беспокойство?",
)


def _screen_pair(raw, items: tuple) -> Optional[int]:
    """Привести ответы скринера к сумме 0..6. None — опрос не проходили.

    Принимаем и список `[a, b]`, и словарь с именованными пунктами: клиенты
    заполняют скринер по-разному, а ронять анализ из-за формата глупо.
    """
    if raw in (None, "", [], {}):
        return None
    values = []
    if isinstance(raw, dict):
        for key in items:
            values.append(_num(raw.get(key)))
    elif isinstance(raw, (list, tuple)):
        values = [_num(v) for v in raw[:2]]
    else:
        return None
    if len(values) != 2 or any(v is None for v in values):
        return None
    return int(sum(_clamp(v, 0, 3) for v in values))


def screen_mental(health: dict) -> dict:
    """PHQ-2 и GAD-2 по данным журнала. Пустой dict, если ничего не заполнено."""
    out: dict = {}
    phq2 = _screen_pair(health.get("phq2"), PHQ2_ITEMS)
    if phq2 is not None:
        out["phq2"] = {
            "score": phq2, "max": 6, "cutoff": SCREEN_CUTOFF,
            "positive": phq2 >= SCREEN_CUTOFF,
            "label": "депрессивные симптомы",
        }
    gad2 = _screen_pair(health.get("gad2"), GAD2_ITEMS)
    if gad2 is not None:
        out["gad2"] = {
            "score": gad2, "max": 6, "cutoff": SCREEN_CUTOFF,
            "positive": gad2 >= SCREEN_CUTOFF,
            "label": "тревожные симптомы",
        }
    return out


# ── Тренды журнала ──────────────────────────────────────────────────

TREND_MIN_POINTS = 4       # на трёх точках «тренд» — это шум

# Что считаем ухудшением: ключ → (наклон-порог, «выше — лучше?», подпись).
_TREND_RULES = {
    "mood":        (-0.15, True,  "настроение"),
    "sleep_hours": (-0.20, True,  "сон"),
    "steps":       (-300.0, True, "активность"),
    "stress":      (0.15,  False, "стресс"),
}


def _slope(values: list) -> Optional[float]:
    """Наклон методом наименьших квадратов по индексу. None — данных мало."""
    nums = [v for v in (_num(x) for x in values) if v is not None]
    n = len(nums)
    if n < TREND_MIN_POINTS:
        return None
    mean_x = (n - 1) / 2.0
    mean_y = sum(nums) / n
    denom = sum((i - mean_x) ** 2 for i in range(n))
    if denom == 0:
        return None
    return sum((i - mean_x) * (y - mean_y) for i, y in enumerate(nums)) / denom


def analyze_trends(series: dict) -> dict:
    """Разобрать ряды журнала на тренды: куда движется каждый показатель.

    `series` — {"mood": [...], "sleep_hours": [...], ...}, значения в
    хронологическом порядке. Ряды короче TREND_MIN_POINTS игнорируются.
    """
    out: dict = {}
    for key, (threshold, higher_is_better, label) in _TREND_RULES.items():
        slope = _slope(series.get(key) or [])
        if slope is None:
            continue
        if higher_is_better:
            worsening = slope <= threshold
            improving = slope >= -threshold
        else:
            worsening = slope >= threshold
            improving = slope <= -threshold
        out[key] = {
            "slope": round(slope, 3),
            "label": label,
            "direction": "хуже" if worsening else ("лучше" if improving else "ровно"),
            "worsening": worsening,
        }
    return out


def _series_of(health: dict) -> dict:
    """Достать ряды из журнала: и вложенным `series`, и плоскими `*_series`."""
    series = dict(health.get("series") or {})
    for key in _TREND_RULES:
        flat = health.get(f"{key}_series")
        if flat:
            series[key] = flat
    return series


# ── Автономный мед-анализ состояния ─────────────────────────────────

def assess_health(health: dict) -> dict:
    """Локальная оценка самочувствия без нейросети.

    Не диагноз и не замена врача — ориентир по простым порогам плюс
    практичные рекомендации «голосом» ассистента. Работает всегда.
    """
    score = 75
    flags: list = []
    recs: list = []

    steps = _num(health.get("steps"))
    if steps is not None:
        if steps < 2000:
            score -= 12
            flags.append("мало активности")
            recs.append("Постарайся пройтись хотя бы 20–30 минут.")
        elif steps >= 8000:
            score += 5

    sleep = _num(health.get("sleep_hours"))
    if sleep is not None:
        if sleep < 6:
            score -= 15
            flags.append("недосып")
            recs.append("Сон меньше 6 часов бьёт по вниманию и настроению — добери отдых.")
        elif sleep > 9:
            score -= 5
            flags.append("пересып")

    # Скринеры считаем до разовых отметок: PHQ-2 спрашивает ровно про то же,
    # что галочка «настроение», а GAD-2 — про то же, что «стресс». Если
    # валидированный опрос заполнен, судим по нему и разовую отметку не
    # штрафуем: иначе один признак наказывался бы дважды и шкала упиралась в 0.
    screens = screen_mental(health)

    mood = _num(health.get("mood"))          # 1..5, выше — лучше
    if "phq2" not in screens and mood is not None and mood <= 2:
        score -= 15
        flags.append("сниженное настроение")
        recs.append("Настроение низкое несколько дней подряд — стоит поговорить с близким или специалистом.")

    stress = _num(health.get("stress"))      # 1..5, выше — хуже
    if "gad2" not in screens and stress is not None and stress >= 4:
        score -= 15
        flags.append("высокий стресс")
        recs.append("Высокий стресс: короткая прогулка и дыхательная пауза помогут снять пик.")

    trend = _num(health.get("weight_trend_kg"))
    if trend is not None and abs(trend) >= 3:
        score -= 8
        direction = "снижение" if trend < 0 else "рост"
        flags.append(f"резкое изменение веса ({direction})")
        recs.append("Резкое изменение веса за месяц — если не намеренно, покажись врачу.")

    # Скринеры: положительный PHQ-2/GAD-2 весит больше разового «плохого дня»,
    # потому что спрашивает про устойчивую картину за две недели.
    for key, res in screens.items():
        if res["positive"]:
            score -= 20
            flags.append(f"{res['label']} по {key.upper()} ({res['score']}/6)")
    if screens.get("phq2", {}).get("positive"):
        recs.append("PHQ-2 положительный — это не диагноз, но повод пройти полную шкалу "
                    "с врачом или психологом.")
    if screens.get("gad2", {}).get("positive"):
        recs.append("GAD-2 положительный — тревога держится не первый день; "
                    "стоит обсудить это со специалистом.")

    # Тренды: одна плохая точка — случайность, устойчивое сползание — сигнал.
    trends = analyze_trends(_series_of(health))
    worsening = [t["label"] for t in trends.values() if t["worsening"]]
    if worsening:
        score -= 5 * len(worsening)
        flags.append("ухудшается: " + ", ".join(worsening))
        recs.append("Показатели сползают несколько дней подряд — "
                    "посмотри, что изменилось в режиме.")

    score = _clamp(score, 0, 100)

    if not flags:
        summary = f"{CALLSIGN}: по данным всё в норме, тревожных признаков не вижу."
        recs = recs or ["Так держать — продолжай в том же ритме."]
    else:
        summary = f"{CALLSIGN}: обратил внимание на — " + ", ".join(flags) + "."

    return {
        "score": score,
        "summary": summary,
        "recommendations": recs[:4],
        "flags": flags,
        "screens": screens,
        "trends": trends,
        "source": "aegis",
        "callsign": CALLSIGN,
    }


def _num(v) -> Optional[float]:
    """Аккуратно привести значение к числу; None/пусто/мусор → None."""
    if v in (None, "", []):
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


# ── Самопроверка при прямом запуске ─────────────────────────────────
if __name__ == "__main__":
    scenarios = [
        ("День, набережная, идёт",
         dict(hour=14, place_type="набережная", route_deviation="", speed_mps=1.4)),
        ("Глубокая ночь, промзона, стоит, далеко",
         dict(hour=3, place_type="промзона склад", route_deviation="далеко (12 км)", speed_mps=0.1)),
        ("Вечер, дорога домой",
         dict(hour=21, place_type="центр", route_deviation="умеренно", speed_mps=3.0)),
    ]
    for title, ctx in scenarios:
        v = assess_situation(**ctx)
        print(f"\n### {title}")
        print(f"  подозрение={v.suspicion} действие={v.action} уверенность={v.confidence}")
        print(f"  причина: {v.reason}")
        print(f"  голос:   {v.voice}")

    print("\n### Здоровье: недосып + стресс")
    h = assess_health(dict(steps=1500, sleep_hours=4.5, mood=2, stress=5, weight_trend_kg=-4))
    print(f"  score={h['score']} флаги={h['flags']}")
    print(f"  {h['summary']}")
    for r in h["recommendations"]:
        print(f"   • {r}")
