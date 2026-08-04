"""
╔══════════════════════════════════════════════════════════════╗
║  O.R.I.O.N. SECURITY  —  auth + rate limiting для core        ║
╚══════════════════════════════════════════════════════════════╝

Лёгкая защита без внешних зависимостей и БД:
  • require_api_key — общий ключ ORION_API_KEY в заголовке X-Orion-Key.
    Если ключ в окружении не задан — auth выключен (dev-режим), но
    core печатает предупреждение при старте.
  • RateLimiter — счётчик запросов на клиента (IP) в скользящем окне,
    чтобы SOS/ingest-эндпоинты нельзя было заспамить.

Сравнение ключей — constant-time (hmac.compare_digest), чтобы не утекало
время сравнения.
"""

from __future__ import annotations

import hmac
import os
import time
from collections import defaultdict, deque
from typing import Deque, Dict

from fastapi import Header, HTTPException, Request


def api_key_configured() -> bool:
    return bool(os.getenv("ORION_API_KEY", "").strip())


async def require_api_key(x_orion_key: str = Header(default="")) -> None:
    """FastAPI-зависимость: пускает, если ключ верен или auth выключен."""
    expected = os.getenv("ORION_API_KEY", "").strip()
    if not expected:
        return  # dev-режим: ключ не задан → не проверяем
    if not x_orion_key or not hmac.compare_digest(x_orion_key, expected):
        raise HTTPException(status_code=401, detail="Неверный или отсутствующий X-Orion-Key")


class RateLimiter:
    """Простой лимитер: не более `limit` запросов за `window` секунд на ключ."""

    def __init__(self, limit: int, window: float):
        self.limit = limit
        self.window = window
        self._hits: Dict[str, Deque[float]] = defaultdict(deque)

    def check(self, key: str) -> bool:
        now = time.monotonic()
        dq = self._hits[key]
        cutoff = now - self.window
        while dq and dq[0] < cutoff:
            dq.popleft()
        if len(dq) >= self.limit:
            return False
        dq.append(now)
        return True

    def dependency(self):
        """Вернуть FastAPI-зависимость, ограничивающую по client IP."""
        async def _dep(request: Request) -> None:
            client = request.client.host if request.client else "unknown"
            if not self.check(client):
                raise HTTPException(status_code=429, detail="Слишком много запросов")
        return _dep
