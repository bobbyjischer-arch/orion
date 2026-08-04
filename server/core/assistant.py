"""
╔══════════════════════════════════════════════════════════════╗
║  O.R.I.O.N. PERSONAL ASSISTANT  —  «личный помощник»          ║
║  Финансовый трекер + детектор подозрительных операций;       ║
║  заглушка «умного дома» (безопасный плейсхолдер, без I/O).    ║
╚══════════════════════════════════════════════════════════════╝

Назначение
----------
Модуль расширяет Telegram-бота O.R.I.O.N. бытовыми функциями. В отличие
от core/suspicion.py (оценка ФИЗИЧЕСКОЙ опасности пользователя) здесь —
наблюдение за ФИНАНСАМИ: аномальные траты часто сопровождают мошенничество,
принуждение или потерю карты, поэтому подозрительные операции помечаются
человекочитаемыми флагами на русском.

Две независимые функции
-----------------------
  1. FinanceTracker — журнал операций в JSON-файле рядом с модулем.
     Каждая операция при добавлении проверяется набором эвристик и
     возвращается вместе со списком «флагов» подозрительности.

  2. SmartHome — ЗАГЛУШКА управления умным домом. Реального I/O с
     устройствами НЕТ: только словарь состояний в памяти. Сцена «тревога»
     помечена как предохранительный хук (включает весь свет).

Эвристики подозрительности (FinanceTracker)
-------------------------------------------
  • «крупная сумма»     — |сумма| >= large_threshold (по умолч. 50000);
  • «необычно крупная»  — |сумма| >= 3× медианы модулей последних 20
                          операций (только при >=5 предыдущих);
  • «серия трат»        — 4-я+ трата (отрицательная сумма) за 10 минут;
  • «ночная операция»   — час операции в диапазоне 1..5 включительно.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta
from statistics import median

# Файл журнала по умолчанию — рядом с модулем, независимо от cwd.
_HERE = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_LEDGER = os.path.join(_HERE, "finance_ledger.json")

# Порог «крупной суммы» по умолчанию (в рублях).
_LARGE_THRESHOLD = 50000.0


def _parse_ts(ts: str) -> datetime | None:
    """Мягкий разбор ISO-времени; None при неудаче (журнал не должен падать)."""
    try:
        return datetime.fromisoformat(ts)
    except (ValueError, TypeError):
        return None


class FinanceTracker:
    """Журнал финансовых операций с детектором подозрительных транзакций.

    Операции хранятся списком словарей в JSON-файле. Положительная сумма —
    доход, отрицательная — трата. Загрузка устойчива к отсутствию файла и
    к битому JSON: в этих случаях журнал стартует пустым и не бросает.
    """

    def __init__(self, path: str = _DEFAULT_LEDGER, large_threshold: float = _LARGE_THRESHOLD):
        self.path = path
        self.large_threshold = float(large_threshold)
        self.transactions: list[dict] = self._load()

    # ── персистентность ────────────────────────────────────────────
    def _load(self) -> list[dict]:
        """Читает журнал; при отсутствии файла или битом JSON — пустой список."""
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError, OSError, ValueError):
            return []
        return data if isinstance(data, list) else []

    def _save(self) -> None:
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump(self.transactions, f, ensure_ascii=False, indent=2)

    # ── детектор подозрительности ──────────────────────────────────
    def _flags(self, amount: float, ts: str) -> list[str]:
        """Человекочитаемые причины подозрительности операции (пусто — норма)."""
        flags: list[str] = []
        amt = abs(amount)

        # Крупная абсолютная сумма.
        if amt >= self.large_threshold:
            flags.append("крупная сумма")

        # Необычно крупная относительно недавней истории.
        prev = self.transactions[-20:]
        if len(prev) >= 5:
            med = median(abs(float(t.get("amount", 0.0))) for t in prev)
            if med > 0 and amt >= 3 * med:
                flags.append("необычно крупная")

        # Серия трат: 4-я+ отрицательная операция за последние 10 минут.
        now = _parse_ts(ts)
        if amount < 0 and now is not None:
            window_start = now - timedelta(minutes=10)
            recent_spends = 0
            for t in self.transactions:
                if float(t.get("amount", 0.0)) >= 0:
                    continue
                t_ts = _parse_ts(t.get("ts", ""))
                if t_ts is not None and window_start <= t_ts <= now:
                    recent_spends += 1
            if recent_spends >= 3:  # эта операция станет 4-й+
                flags.append("серия трат")

        # Ночная операция (1..5 включительно).
        if now is not None and 1 <= now.hour <= 5:
            flags.append("ночная операция")

        return flags

    # ── публичный API ──────────────────────────────────────────────
    def add_transaction(
        self,
        amount: float,
        category: str = "",
        note: str = "",
        ts: str | None = None,
    ) -> dict:
        """Добавляет операцию, сохраняет журнал и возвращает её со «флагами».

        Флаги вычисляются ДО добавления (по прошлой истории), чтобы «серия
        трат» считала именно предыдущие операции, а не саму себя.
        """
        ts = ts or datetime.now().isoformat()
        flags = self._flags(float(amount), ts)
        tx = {
            "amount": float(amount),
            "category": category,
            "note": note,
            "ts": ts,
        }
        self.transactions.append(tx)
        self._save()
        return {**tx, "flags": flags}

    def summary(self, days: int = 30) -> dict:
        """Итоги за окно в днях: доход, траты, сальдо, счётчик и подозрительные."""
        cutoff = datetime.now() - timedelta(days=days)
        income = 0.0
        spend = 0.0
        count = 0
        suspicious: list[dict] = []
        for t in self.transactions:
            t_ts = _parse_ts(t.get("ts", ""))
            if t_ts is not None and t_ts < cutoff:
                continue
            count += 1
            amount = float(t.get("amount", 0.0))
            if amount >= 0:
                income += amount
            else:
                spend += amount
            flags = self._flags(amount, t.get("ts", ""))
            if flags:
                suspicious.append({**t, "flags": flags})
        return {
            "days": days,
            "income": round(income, 2),
            "spend": round(spend, 2),
            "net": round(income + spend, 2),
            "count": count,
            "suspicious": suspicious,
        }

    def recent(self, n: int = 10) -> list:
        """Последние n операций (в хронологическом порядке)."""
        return self.transactions[-n:]


class SmartHome:
    """ЗАГЛУШКА управления умным домом — безопасный плейсхолдер.

    Реального взаимодействия с устройствами НЕТ: только словарь состояний
    в памяти. Класс задаёт стабильный API (set_state/get_state/list_devices/
    scene) на замену будущей интеграции с реальным хабом (Home Assistant,
    MQTT и т.п.). Никаких внешних вызовов и сетевого I/O.
    """

    # Встроенные сцены: имя → {устройство: состояние}.
    _SCENES: dict[str, dict[str, str]] = {
        "дом":     {"свет": "вкл", "чайник": "вкл", "музыка": "вкл"},
        "уход":    {"свет": "выкл", "чайник": "выкл", "музыка": "выкл"},
        # Предохранительный хук: тревога включает ВЕСЬ свет —
        # освещённое жильё безопаснее и помогает при экстренной ситуации.
        "тревога": {"свет": "вкл", "прихожая": "вкл", "кухня": "вкл", "спальня": "вкл"},
    }

    def __init__(self):
        self.devices: dict[str, str] = {}

    def set_state(self, device: str, state: str) -> dict:
        """Задаёт состояние устройства (напр. свет→вкл). Возвращает запись."""
        self.devices[device] = state
        return {"device": device, "state": state}

    def get_state(self, device: str) -> str | None:
        """Текущее состояние устройства либо None, если оно неизвестно."""
        return self.devices.get(device)

    def list_devices(self) -> dict:
        """Копия текущей карты устройств и их состояний."""
        return dict(self.devices)

    def scene(self, name: str) -> dict:
        """Применяет встроенную сцену по имени; возвращает применённые состояния."""
        preset = self._SCENES.get(name)
        if preset is None:
            return {"applied": False, "scene": name, "devices": self.list_devices()}
        for device, state in preset.items():
            self.devices[device] = state
        return {"applied": True, "scene": name, "devices": self.list_devices()}
