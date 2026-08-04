"""
╔══════════════════════════════════════════════════════════════╗
║  O.R.I.O.N. STORE  —  простое персистентное хранилище        ║
╚══════════════════════════════════════════════════════════════╝

Зачем: на free-тарифе Render сервис засыпает и процесс перезапускается —
всё, что жило только в памяти, теряется. Историю перемещений и память
«мозга» терять нельзя, поэтому они пишутся на диск JSON-файлом.

Файл берётся из ORION_DATA_DIR (по умолчанию — каталог `data/` рядом с
server/). На Render без диска каталог эфемерный: данные живут до
редеплоя, но переживают сон/перезапуск процесса — этого достаточно, а с
подключённым Persistent Disk (платный) станет полностью надёжно.

Модель данных проста:
  devices: {device_id: {last_location, last_seen}}
  tracks:  {device_id: [точка, точка, …]}
  brain:   {ключ: состояние AEGIS}
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List

# Сколько точек трека держим на устройство. 3000 — это около недели
# непрерывной записи при точке раз в 5 минут; историю смотрят по датам
# за недели, а файл при этом остаётся в пределах пары мегабайт.
MAX_TRACK_POINTS = 3000


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def data_dir() -> Path:
    raw = os.getenv("ORION_DATA_DIR", "").strip()
    base = Path(raw) if raw else Path(__file__).resolve().parent.parent / "data"
    base.mkdir(parents=True, exist_ok=True)
    return base


class Store:
    """Потокобезопасное JSON-хранилище устройств, их трека и памяти «мозга»."""

    def __init__(self, filename: str = "orion_store.json"):
        self._lock = threading.RLock()
        self._path = data_dir() / filename
        self._state: Dict[str, Any] = {"devices": {}, "tracks": {}, "brain": {}}
        self._load()

    # ── Диск ──────────────────────────────────────────────────────

    def _load(self) -> None:
        try:
            raw = self._path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return
        try:
            loaded = json.loads(raw)
        except json.JSONDecodeError:
            # Без эмодзи: на Windows-консоли (cp1251) они роняют print.
            print(f"[STORE] WARN: {self._path.name} повреждён — начинаем с пустого состояния.")
            return
        if isinstance(loaded, dict):
            for key in ("devices", "tracks", "brain"):
                if isinstance(loaded.get(key), dict):
                    self._state[key] = loaded[key]

    def _flush(self) -> None:
        """Атомарная запись: сначала во временный файл, потом replace."""
        try:
            fd, tmp = tempfile.mkstemp(dir=str(self._path.parent), suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    json.dump(self._state, fh, ensure_ascii=False)
                os.replace(tmp, self._path)
            except BaseException:
                Path(tmp).unlink(missing_ok=True)
                raise
        except OSError as e:
            # Диск может быть read-only — сервер должен продолжать работать.
            print(f"[STORE] WARN: не удалось сохранить состояние: {e}")

    # ── Память «мозга» ────────────────────────────────────────────

    def get_brain(self, key: str) -> Dict[str, Any]:
        """Сохранённое состояние AEGIS (память обстановки). {} — ничего нет."""
        with self._lock:
            value = self._state["brain"].get(key)
            return dict(value) if isinstance(value, dict) else {}

    def save_brain(self, key: str, value: Dict[str, Any]) -> None:
        """Положить состояние «мозга» на диск: память должна пережить рестарт."""
        with self._lock:
            self._state["brain"][key] = value
            self._flush()

    # ── Устройства ────────────────────────────────────────────────

    def add_track_point(self, device_id: str, point: dict) -> None:
        """Точка трека устройства + обновление last_location."""
        with self._lock:
            track: List[dict] = self._state["tracks"].setdefault(device_id, [])
            track.append(point)
            if len(track) > MAX_TRACK_POINTS:
                del track[:-MAX_TRACK_POINTS]
            dev = self._state["devices"].setdefault(device_id, {})
            dev["last_location"] = point
            dev["last_seen"] = _now_iso()
            self._flush()

    def track(self, device_id: str, limit: int = 200) -> List[dict]:
        with self._lock:
            return list(self._state["tracks"].get(device_id, []))[-limit:]

    def track_filtered(self, device_id: str = "", since: str = "", until: str = "",
                       place: str = "", limit: int = 500) -> List[dict]:
        """Точки трека с фильтрами «дата/время» и «место».

        Пустой device_id — по всем устройствам сразу: у владельца может быть
        несколько телефонов, а шкала истории должна быть одна.

        Сравнение времени строковое и обрезанное до `YYYY-MM-DDTHH:MM:SS`:
        точки приходят и с суффиксом смещения (`+00:00`, `Z`), и без него, а
        такой префикс сортируется лексикографически одинаково в обоих случаях.
        Границы можно задавать частично — `"2026-08-04"` значит «весь день».
        Место ищем подстрокой без учёта регистра: фильтр набирают руками.
        """
        needle = place.strip().lower()
        lo = since.strip()[:19]
        hi = until.strip()[:19]
        # «до 2026-08-04» без времени должно включать весь день, а не отсечь
        # его на полуночи — дополняем верхнюю границу максимальным временем.
        if hi and len(hi) == 10:
            hi += "T23:59:59"
        with self._lock:
            buckets = (
                [(device_id, self._state["tracks"].get(device_id, []))]
                if device_id
                else list(self._state["tracks"].items())
            )
            out: List[dict] = []
            for did, points in buckets:
                for p in points:
                    ts = str(p.get("timestamp", ""))[:19]
                    if lo and ts < lo:
                        continue
                    if hi and ts > hi:
                        continue
                    if needle and needle not in str(p.get("place", "")).lower():
                        continue
                    out.append({**p, "device_id": did})
        out.sort(key=lambda p: str(p.get("timestamp", "")))
        return out[-limit:] if limit > 0 else out

    def track_places(self, device_id: str = "") -> List[str]:
        """Различные названия мест в треке — чтобы фильтр можно было подсказать."""
        with self._lock:
            buckets = (
                [self._state["tracks"].get(device_id, [])]
                if device_id
                else list(self._state["tracks"].values())
            )
            seen = {
                str(p.get("place", "")).strip()
                for points in buckets for p in points
                if str(p.get("place", "")).strip()
            }
        return sorted(seen)

    def devices(self) -> Dict[str, dict]:
        with self._lock:
            return json.loads(json.dumps(self._state["devices"]))

    # ── Тесты / обслуживание ──────────────────────────────────────

    def reset(self) -> None:
        with self._lock:
            self._state = {"devices": {}, "tracks": {}, "brain": {}}
            self._flush()
