"""
╔══════════════════════════════════════════════════════════════╗
║  O.R.I.O.N. SUSPICION COUNTER  —  «Счётчик подозрений»       ║
║  Динамическая, НАКАПЛИВАЕМАЯ оценка опасности с затуханием.  ║
╚══════════════════════════════════════════════════════════════╝

Отличие от разового LLM-скоринга в llm.py: там — мгновенная оценка одного
контекста. Здесь — счётчик с памятью: он растёт при повторяющихся признаках
опасности и затухает, когда всё спокойно. Это ближе к формулировке ТЗ
(«счётчик подозрений начинает расти»).

Вклад в мгновенный уровень (instant, 0..100) складывается из:
  • время суток          — глубокая ночь опаснее;
  • тип местности        — промзона/пустырь опаснее набережной/парка;
  • отклонение от маршрута — «далеко» от привычной зоны повышает;
  • скорость             — долгая почти-нулевая скорость ночью настораживает.

Накопитель (level) движется к instant с инерцией: быстро вверх, медленно вниз
(EMA с разными коэффициентами). Так одиночный выброс не паникует систему,
а устойчивая опасная картина плавно поднимает уровень до порога опроса.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

# Порог, при котором стоит инициировать опрос состояния пользователя.
ASK_THRESHOLD = 60

# Классификация местности → базовый вклад в подозрение.
_ZONE_WEIGHTS = {
    "промзон":    35, "пустыр": 35, "склад": 25, "стройк": 25,
    "гараж":      20, "отшиб":  30, "лес":    20, "трасс":  10,
    "набережн":  -15, "парк":  -15, "кафе":  -10, "тц":    -10,
    "центр":      -5, "дом":   -20, "работ": -15,
}


def _hour_score(hour: Optional[int]) -> int:
    """Вклад времени суток."""
    if hour is None:
        return 0
    if 2 <= hour < 5:      # глубокая ночь
        return 35
    if 23 <= hour or hour < 2:
        return 25
    if 5 <= hour < 7 or 21 <= hour < 23:
        return 10
    return 0               # день


def _zone_score(place_type: str) -> int:
    p = (place_type or "").lower()
    score = 0
    for key, w in _ZONE_WEIGHTS.items():
        if key in p:
            score += w
    return score


def _deviation_score(route_deviation: str) -> int:
    d = (route_deviation or "").lower()
    if "далеко" in d:
        return 25
    if "умеренно" in d:
        return 10
    return 0


def _speed_score(speed_mps: Optional[float], hour: Optional[int]) -> int:
    """Долгая почти-нулевая скорость ночью — настораживает; движение — норма."""
    if speed_mps is None:
        return 0
    night = hour is not None and (hour >= 22 or hour < 6)
    if speed_mps < 0.3 and night:
        return 15
    if speed_mps > 2.5:      # уверенно движется (идёт/едет) — чуть спокойнее
        return -5
    return 0


def _clamp(v: float, lo: int = 0, hi: int = 100) -> int:
    return int(max(lo, min(hi, round(v))))


def instant_suspicion(
    *,
    hour: Optional[int],
    place_type: str = "",
    route_deviation: str = "",
    speed_mps: Optional[float] = None,
) -> tuple[int, str]:
    """Мгновенная оценка (0..100) + человекочитаемая причина."""
    base = 20
    parts = []
    hs = _hour_score(hour)
    if hs:
        parts.append(("ночное время" if hs >= 25 else "вечер/раннее утро", hs))
    zs = _zone_score(place_type)
    if zs > 0:
        parts.append(("нетипичная местность", zs))
    elif zs < 0:
        parts.append(("безопасное место", zs))
    ds = _deviation_score(route_deviation)
    if ds:
        parts.append(("отклонение от маршрута", ds))
    ss = _speed_score(speed_mps, hour)
    if ss > 0:
        parts.append(("подозрительно неподвижен", ss))

    total = _clamp(base + hs + zs + ds + ss)
    if not parts:
        reason = "обычная обстановка"
    else:
        parts.sort(key=lambda x: -abs(x[1]))
        reason = ", ".join(p[0] for p in parts[:3])
    return total, reason


@dataclass
class SuspicionCounter:
    """Накопитель подозрения с инерцией и затуханием.

    level поднимается быстро (RISE) и опускается медленно (FALL) к instant.
    Так система реагирует на нарастающую опасность, но не «прыгает» от шума.
    """
    level: float = 20.0
    last_update: Optional[str] = None
    RISE: float = 0.6          # коэффициент подъёма (доля пути к instant)
    FALL: float = 0.15         # коэффициент спада

    def update(
        self,
        *,
        hour: Optional[int],
        place_type: str = "",
        route_deviation: str = "",
        speed_mps: Optional[float] = None,
    ) -> dict:
        instant, reason = instant_suspicion(
            hour=hour, place_type=place_type,
            route_deviation=route_deviation, speed_mps=speed_mps,
        )
        alpha = self.RISE if instant > self.level else self.FALL
        self.level = self.level + alpha * (instant - self.level)
        self.last_update = datetime.now().isoformat()
        lvl = _clamp(self.level)
        return {
            "level": lvl,
            "instant": instant,
            "reason": reason,
            "should_ask": lvl >= ASK_THRESHOLD,
            "question": "Всё ли с тобой хорошо?" if lvl >= ASK_THRESHOLD else "",
            "rising": instant > lvl,
        }

    def decay_only(self) -> int:
        """Затухание без нового наблюдения (напр. по таймеру покоя)."""
        self.level = self.level + self.FALL * (20.0 - self.level)
        return _clamp(self.level)

    def to_dict(self) -> dict:
        return {"level": _clamp(self.level), "last_update": self.last_update}
