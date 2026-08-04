"""
╔══════════════════════════════════════════════════════════════════╗
║  A.E.G.I.S. MEMORY  —  память «мозга» O.R.I.O.N.                 ║
╚══════════════════════════════════════════════════════════════════╝

Чего не хватало AEGIS v1
────────────────────────
`assess_situation` — чистая функция: она видит один срез обстановки и ничего
не помнит. Из-за этого две принципиально разные картины выглядели одинаково:
человек только что пришёл на пустырь — и человек стоит там сорок минут.
`SuspicionCounter` из suspicion.py помнил уровень, но затухал «за вызов», а не
за время: пропали наблюдения на два часа — счётчик так и остался высоким.

AegisMemory закрывает три дыры:

  • **Затухание по времени.** Уровень тянется к покою с периодом полураспада,
    считанным от реальных минут между наблюдениями, а не от их количества.
  • **Привычные места.** Координаты квантуются в ячейки ~110 м; ячейка
    становится привычной после нескольких визитов в разные дни. Знакомое
    место успокаивает, незнакомое — чуть настораживает.
  • **Dwell.** Сколько минут человек фактически стоит в одной ячейке. Это
    отдельный сигнал: неподвижность «прямо сейчас» и неподвижность «сорок
    минут подряд» — разные вещи.

Модуль остаётся полностью автономным: ни сети, ни нейросети, ни БД.
Состояние сериализуется в dict, поэтому его можно положить в core/store.py.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

from core.suspicion import _clamp

# ── Настройки памяти ────────────────────────────────────────────────

BASELINE = 20.0            # «покой»: к нему затухает уровень
HALF_LIFE_MIN = 45.0       # за столько минут покоя уровень проходит полпути к BASELINE
RISE = 0.6                 # доля пути к instant при росте (как в SuspicionCounter)

CELL_PRECISION = 3         # знаков после запятой у координат: ~110 м
HABITUAL_VISITS = 3        # визитов, чтобы место считалось привычным
HABITUAL_DAYS = 2          # и в стольких разных днях
MAX_PLACES = 200           # больше не храним — вытесняем самые старые

STILL_SPEED_MPS = 0.5      # ниже этого считаем, что человек стоит
DWELL_GAP_MIN = 30.0       # разрыв в наблюдениях длиннее — dwell начинаем заново


def cell_of(lat: Optional[float], lon: Optional[float]) -> Optional[str]:
    """Квантовать координату в ячейку сетки. None, если координат нет."""
    if lat is None or lon is None:
        return None
    try:
        la, lo = float(lat), float(lon)
    except (TypeError, ValueError):
        return None
    if not (math.isfinite(la) and math.isfinite(lo)):
        return None
    return f"{la:.{CELL_PRECISION}f},{lo:.{CELL_PRECISION}f}"


def _parse(ts: Optional[str]) -> Optional[datetime]:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts)
    except (TypeError, ValueError):
        return None


@dataclass
class Place:
    """Одна запомненная ячейка карты."""
    cell: str
    visits: int = 0
    days: list = field(default_factory=list)   # ISO-даты визитов, без повторов
    minutes: float = 0.0                       # суммарно проведено минут
    last_seen: Optional[str] = None

    @property
    def habitual(self) -> bool:
        return self.visits >= HABITUAL_VISITS and len(self.days) >= HABITUAL_DAYS

    def to_dict(self) -> dict:
        return {"cell": self.cell, "visits": self.visits, "days": list(self.days),
                "minutes": round(self.minutes, 1), "last_seen": self.last_seen}

    @classmethod
    def from_dict(cls, d: dict) -> "Place":
        return cls(
            cell=d.get("cell", ""),
            visits=int(d.get("visits", 0) or 0),
            days=list(d.get("days", []) or []),
            minutes=float(d.get("minutes", 0.0) or 0.0),
            last_seen=d.get("last_seen"),
        )


@dataclass
class AegisMemory:
    """Память обстановки: уровень с затуханием по времени, места, dwell."""

    level: float = BASELINE
    last_update: Optional[str] = None
    places: dict = field(default_factory=dict)      # cell → Place
    dwell_cell: Optional[str] = None
    dwell_minutes: float = 0.0
    dwell_since: Optional[str] = None

    # ── Затухание ───────────────────────────────────────────────────

    def _decayed(self, now: datetime) -> float:
        """Уровень, притянутый к покою за прошедшее время. Ничего не меняет."""
        prev = _parse(self.last_update)
        if prev is None:
            return self.level
        minutes = max(0.0, (now - prev).total_seconds() / 60.0)
        # Экспоненциальное затухание с периодом полураспада.
        return BASELINE + (self.level - BASELINE) * (0.5 ** (minutes / HALF_LIFE_MIN))

    def level_at(self, now: Optional[datetime] = None) -> int:
        """Каким уровень стал бы к моменту `now`, если наблюдений так и не было.

        Отдельно от decay_to, потому что читающей стороне (дашборд, /status)
        нельзя двигать last_update: иначе следующий observe увидел бы нулевой
        разрыв и dwell перестал бы накапливаться от одного лишь опроса статуса.
        """
        return _clamp(self._decayed(now or datetime.now()))

    def decay_to(self, now: datetime) -> int:
        """Притянуть уровень к покою за прошедшее время. Без наблюдения."""
        self.level = self._decayed(now)
        self.last_update = now.isoformat()
        return _clamp(self.level)

    # ── Наблюдение ──────────────────────────────────────────────────

    def observe(
        self,
        *,
        instant: int,
        lat: Optional[float] = None,
        lon: Optional[float] = None,
        speed_mps: Optional[float] = None,
        now: Optional[datetime] = None,
    ) -> dict:
        """Учесть одно наблюдение и вернуть срез памяти.

        `instant` — мгновенная оценка обстановки (её считает AEGIS/suspicion).
        Память отвечает только за накопление, места и dwell.
        """
        now = now or datetime.now()
        prev = _parse(self.last_update)
        gap_min = (now - prev).total_seconds() / 60.0 if prev else 0.0

        # 1. Сначала затухание за прошедшее время, потом подъём к instant.
        #    Порядок важен: иначе свежий всплеск сразу же «съедался» бы спадом.
        self.level = self._decayed(now)
        if instant > self.level:
            self.level = self.level + RISE * (instant - self.level)

        cell = cell_of(lat, lon)
        moved = cell is not None and cell != self.dwell_cell
        still = speed_mps is None or speed_mps < STILL_SPEED_MPS

        # 2. Dwell: копим минуты, пока ячейка та же и человек не разогнался.
        #    Долгий разрыв в наблюдениях обнуляет счёт — что было в паузе,
        #    память не знает и додумывать не станет.
        if cell is None or moved or not still or gap_min > DWELL_GAP_MIN:
            self.dwell_cell = cell
            self.dwell_minutes = 0.0
            self.dwell_since = now.isoformat() if cell else None
        else:
            self.dwell_minutes += max(0.0, gap_min)

        # 3. Места: визит засчитываем при заходе в ячейку, а не на каждый тик.
        if cell is not None:
            place = self._place(cell)
            if moved or place.visits == 0:
                place.visits += 1
            day = now.date().isoformat()
            if day not in place.days:
                place.days.append(day)
            place.minutes += max(0.0, min(gap_min, DWELL_GAP_MIN))
            place.last_seen = now.isoformat()
            self._evict()

        self.last_update = now.isoformat()
        return self.snapshot(lat=lat, lon=lon)

    # ── Срез для рассуждения ────────────────────────────────────────

    def snapshot(self, *, lat: Optional[float] = None, lon: Optional[float] = None,
                 now: Optional[datetime] = None) -> dict:
        """То, что AEGIS должен знать о прошлом, чтобы судить о настоящем.

        `now` — только для чтения со стороны: показать уровень с учётом
        затухания, ничего при этом не сдвинув.
        """
        cell = cell_of(lat, lon) or self.dwell_cell
        known: Optional[bool] = None
        if cell is not None:
            place = self.places.get(cell)
            # None означает «нечего сказать»: место видим впервые и статистики
            # по нему ещё нет. Сигнал «незнакомое» даём только когда память
            # уже успела накопить хоть какую-то картину привычных мест.
            if place is not None and place.habitual:
                known = True
            elif self.habitual_count > 0:
                known = False
        return {
            "level": self.level_at(now) if now is not None else _clamp(self.level),
            "dwell_minutes": round(self.dwell_minutes, 1),
            "place_known": known,
            "cell": cell,
            "habitual_places": self.habitual_count,
            "known_places": len(self.places),
        }

    @property
    def habitual_count(self) -> int:
        return sum(1 for p in self.places.values() if p.habitual)

    # ── Внутреннее ──────────────────────────────────────────────────

    def _place(self, cell: str) -> Place:
        place = self.places.get(cell)
        if place is None:
            place = Place(cell=cell)
            self.places[cell] = place
        return place

    def _evict(self) -> None:
        """Вытеснить самые давно не виденные ячейки, привычные — в последнюю очередь."""
        if len(self.places) <= MAX_PLACES:
            return
        ordered = sorted(
            self.places.values(),
            key=lambda p: (p.habitual, p.last_seen or ""),
        )
        for p in ordered[: len(self.places) - MAX_PLACES]:
            self.places.pop(p.cell, None)

    # ── Сериализация ────────────────────────────────────────────────

    def to_dict(self) -> dict:
        return {
            "level": _clamp(self.level),
            "last_update": self.last_update,
            "dwell_minutes": round(self.dwell_minutes, 1),
            "dwell_cell": self.dwell_cell,
            "dwell_since": self.dwell_since,
            "habitual_places": self.habitual_count,
            "places": [p.to_dict() for p in self.places.values()],
        }

    @classmethod
    def from_dict(cls, d: Optional[dict]) -> "AegisMemory":
        d = d or {}
        mem = cls(
            level=float(d.get("level", BASELINE) or BASELINE),
            last_update=d.get("last_update"),
            dwell_cell=d.get("dwell_cell"),
            dwell_minutes=float(d.get("dwell_minutes", 0.0) or 0.0),
            dwell_since=d.get("dwell_since"),
        )
        for raw in d.get("places", []) or []:
            place = Place.from_dict(raw)
            if place.cell:
                mem.places[place.cell] = place
        return mem
