"""
╔══════════════════════════════════════════════════════╗
║  O.R.I.O.N. LLM  —  внешний слой «мозга»             ║
║  Подключает нейросеть (локальную Ollama / облачный    ║
║  OpenRouter) как УСИЛЕНИЕ поверх автономного мозга    ║
║  A.E.G.I.S. (core/aegis.py).                          ║
╚══════════════════════════════════════════════════════╝

Ключевой принцип
────────────────
Мозг ORION работает ВСЕГДА, даже без интернета и без нейросети. Базовое
рассуждение делает автономный движок A.E.G.I.S. (core/aegis.py). Этот модуль —
лишь необязательная «надстройка»: если рядом есть настоящая нейросеть, он
спрашивает у неё второе мнение; если нет (пустой ключ, не поднята Ollama,
нет сети / мешает VPN) — молча остаётся на AEGIS, а не «слепнет».

Контракт анализа намеренно совпадает с iOS-версией
(Services/LLMService.swift), чтобы «мозг» одинаково думал в приложении и в боте.

Вход  (SuspicionContext): координаты, локальное время, скорость,
       тип местности, близость к точкам интереса.
Выход (SuspicionAssessment, строгий JSON):
       { "suspicion": 0..100, "reason": str,
         "should_ask": bool, "question": str, "source": str }
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from typing import Optional

import httpx

from core import aegis

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
# Список бесплатных моделей OpenRouter ротируется. Этот id рабочий на момент
# написания; если перестанет — поменяй OPENROUTER_MODEL в .env.
DEFAULT_MODEL = "deepseek/deepseek-chat-v3-0324:free"

# ── Локальная нейросеть (Ollama) ─────────────────────────────────
# Облегчённая локальная модель (Gemma/Hermes) для приватного анализа без
# отправки данных в облако — важно для censorship-resistance и приватности
# мед-данных. Управляется переменными окружения (см. .env.example):
#   LLM_BACKEND = auto | ollama | openrouter
#     auto — сначала локальный Ollama, при недоступности — OpenRouter, иначе эвристика.
DEFAULT_OLLAMA_URL = "http://localhost:11434"
DEFAULT_OLLAMA_MODEL = "gemma2:2b"


async def _chat_completion(system: str, user: str, timeout: float) -> Optional[str]:
    """Единая точка вызова ИИ. Возвращает текст ответа или None.

    Выбор бэкенда по LLM_BACKEND. Никогда не бросает — при любой ошибке
    возвращает None, чтобы вызывающий код ушёл в эвристический fallback.
    """
    backend = os.getenv("LLM_BACKEND", "auto").lower()

    if backend in ("ollama", "auto"):
        text = await _ollama_chat(system, user, timeout)
        if text is not None:
            return text
        if backend == "ollama":
            return None  # явно просили локальный — в облако не уходим

    # openrouter или auto-fallback
    return await _openrouter_chat(system, user, timeout)


async def _ollama_chat(system: str, user: str, timeout: float) -> Optional[str]:
    """Запрос к локальному Ollama (/api/chat). None при недоступности."""
    base = os.getenv("OLLAMA_URL", DEFAULT_OLLAMA_URL).rstrip("/")
    model = os.getenv("OLLAMA_MODEL", DEFAULT_OLLAMA_MODEL)
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
        "options": {"temperature": 0.3},
    }
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(f"{base}/api/chat", json=payload, timeout=timeout)
            resp.raise_for_status()
            data = resp.json()
            return data.get("message", {}).get("content")
    except Exception as e:
        print(f"[LLM] ollama unavailable: {e}")
        return None


async def _openrouter_chat(system: str, user: str, timeout: float) -> Optional[str]:
    """Запрос к OpenRouter. None если нет ключа или ошибка."""
    api_key = os.getenv("OPENROUTER_API_KEY", "")
    if not api_key:
        return None
    model = os.getenv("OPENROUTER_MODEL", DEFAULT_MODEL)
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0.3,
        "max_tokens": 400,
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "X-Title": "O.R.I.O.N.",
    }
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(OPENROUTER_URL, json=payload, headers=headers, timeout=timeout)
            resp.raise_for_status()
            data = resp.json()
            return data["choices"][0]["message"]["content"]
    except Exception as e:
        print(f"[LLM] openrouter error: {e}")
        return None


# ── Диагностика бэкендов ─────────────────────────────────────────
# Кэш проверки Ollama, чтобы не дёргать сеть на каждый запрос.
_OLLAMA_PROBE: dict = {"ts": 0.0, "ok": False, "models": []}
_OLLAMA_PROBE_TTL = 30.0  # секунд


async def _probe_ollama(timeout: float = 2.0) -> dict:
    """Проверить, поднята ли локальная Ollama, и какие модели доступны.

    Результат кэшируется на _OLLAMA_PROBE_TTL секунд. Никогда не бросает.
    """
    now = time.monotonic()
    if now - _OLLAMA_PROBE["ts"] < _OLLAMA_PROBE_TTL:
        return _OLLAMA_PROBE
    base = os.getenv("OLLAMA_URL", DEFAULT_OLLAMA_URL).rstrip("/")
    ok, models = False, []
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(f"{base}/api/tags", timeout=timeout)
            resp.raise_for_status()
            data = resp.json()
            models = [m.get("name", "") for m in data.get("models", [])]
            ok = True
    except Exception:
        ok = False
    _OLLAMA_PROBE.update(ts=now, ok=ok, models=models)
    return _OLLAMA_PROBE


async def backend_status() -> dict:
    """Честная картина: чем сейчас «думает» ORION.

    Возвращает состояние автономного мозга (всегда on), локальной нейросети
    и облака, а также активный бэкенд с учётом LLM_BACKEND. Для эндпоинта
    /aegis/status и раздела статуса в дашборде/боте.
    """
    backend = os.getenv("LLM_BACKEND", "auto").lower()
    has_key = bool(os.getenv("OPENROUTER_API_KEY", ""))
    probe = await _probe_ollama()

    ollama_on = probe["ok"] and backend in ("ollama", "auto")
    openrouter_on = has_key and backend in ("openrouter", "auto")

    if ollama_on:
        active = "ollama"
    elif openrouter_on:
        active = "openrouter"
    else:
        active = "aegis"  # автономный мозг — всегда доступен

    return {
        "callsign": aegis.CALLSIGN,
        "tagline": aegis.PERSONA_TAGLINE,
        "backend_pref": backend,
        "active": active,
        "neural_augmented": active != "aegis",
        "aegis": {"available": True, "always_on": True},
        "ollama": {
            "reachable": probe["ok"],
            "models": probe["models"],
            "model": os.getenv("OLLAMA_MODEL", DEFAULT_OLLAMA_MODEL),
        },
        "openrouter": {
            "has_key": has_key,
            "model": os.getenv("OPENROUTER_MODEL", DEFAULT_MODEL),
        },
    }


# Системный промпт — единый источник «характера» O.R.I.O.N.
SYSTEM_PROMPT = (
    "Ты — O.R.I.O.N., система мониторинга безопасности пользователя. "
    "По контексту его местоположения оцени, насколько вероятно, что ему "
    "нужна помощь, по шкале подозрения 0..100.\n"
    "Ориентиры:\n"
    "- день, людное/безопасное место (набережная, парк, кафе) → 0..20\n"
    "- обычное перемещение по городу → 10..35\n"
    "- ночь в нетипичном месте, низкая скорость долго → 40..70\n"
    "- глубокая ночь (2..5) в промзоне/пустыре/на отшибе → 75..100\n"
    "- сильное отклонение от привычных мест маршрута повышает подозрение\n"
    "Если подозрение высокое (>=60) — следует задать пользователю мягкий "
    "уточняющий вопрос, всё ли с ним хорошо.\n"
    "Отвечай СТРОГО одним JSON-объектом без markdown и пояснений, поля:\n"
    '{"suspicion": <int 0..100>, "reason": "<кратко по-русски>", '
    '"should_ask": <true|false>, "question": "<вопрос пользователю или пустая строка>"}'
)


@dataclass
class SuspicionContext:
    """Контекст, который отправляется «мозгу» на анализ."""
    latitude: float
    longitude: float
    local_time: str = ""          # "HH:MM" локального времени пользователя
    speed_mps: Optional[float] = None
    place_type: str = ""          # грубый тип местности: "промзона", "набережная", ...
    near_poi: str = ""            # имя ближайшей точки интереса, если есть
    route_deviation: str = ""     # отклонение от привычных мест, напр. "далеко (12 км)"
    # Из памяти AEGIS (core/aegis_memory.py). None — памяти нет или ей нечего
    # сказать; тогда движок рассуждает ровно как раньше, без этих сигналов.
    dwell_minutes: Optional[float] = None   # сколько минут стоит в одной ячейке
    place_known: Optional[bool] = None      # привычное ли это место
    extra: dict = field(default_factory=dict)

    def to_prompt(self) -> str:
        lines = [
            f"Координаты: {self.latitude:.5f}, {self.longitude:.5f}",
            f"Локальное время: {self.local_time or 'неизвестно'}",
        ]
        if self.speed_mps is not None:
            lines.append(f"Скорость: {self.speed_mps:.1f} м/с")
        if self.place_type:
            lines.append(f"Тип местности: {self.place_type}")
        if self.near_poi:
            lines.append(f"Рядом точка интереса: {self.near_poi}")
        if self.route_deviation:
            lines.append(f"Отклонение от привычных мест: {self.route_deviation}")
        if self.dwell_minutes is not None and self.dwell_minutes >= 1:
            lines.append(f"Стоит на одном месте: {int(self.dwell_minutes)} мин")
        if self.place_known is not None:
            lines.append("Место: " + ("привычное" if self.place_known else "незнакомое"))
        for k, v in self.extra.items():
            lines.append(f"{k}: {v}")
        return "\n".join(lines)


@dataclass
class SuspicionAssessment:
    """Вердикт «мозга». Совпадает с iOS SuspicionAssessment."""
    suspicion: int
    reason: str
    should_ask: bool
    question: str
    source: str = "aegis"         # "aegis" | "aegis+llm" | "llm"
    voice: str = ""               # реплика «голосом» ассистента (от AEGIS)
    action: str = "monitor"       # monitor | ask | prepare_sos
    signals: list = field(default_factory=list)
    confidence: int = 0

    def to_dict(self) -> dict:
        return {
            "suspicion": self.suspicion,
            "reason": self.reason,
            "should_ask": self.should_ask,
            "question": self.question,
            "source": self.source,
            "voice": self.voice,
            "action": self.action,
            "signals": self.signals,
            "confidence": self.confidence,
            "callsign": aegis.CALLSIGN,
        }


def _clamp(v: int, lo: int = 0, hi: int = 100) -> int:
    return max(lo, min(hi, v))


def _aegis_assess(ctx: SuspicionContext, source: str = "aegis") -> SuspicionAssessment:
    """Оценка автономным мозгом AEGIS. Работает всегда, без сети и нейросети.

    Это уже не «грубая заглушка», а полноценное локальное рассуждение с
    учётом опасных сочетаний факторов (core/aegis.py).
    """
    hour = _parse_hour(ctx.local_time)
    verdict = aegis.assess_situation(
        hour=hour,
        place_type=ctx.place_type,
        route_deviation=ctx.route_deviation,
        speed_mps=ctx.speed_mps,
        dwell_minutes=ctx.dwell_minutes,
        place_known=ctx.place_known,
    )
    return SuspicionAssessment(
        suspicion=verdict.suspicion,
        reason=verdict.reason,
        should_ask=verdict.should_ask,
        question=verdict.question,
        source=source,
        voice=verdict.voice,
        action=verdict.action,
        signals=[s.to_dict() for s in verdict.signals],
        confidence=verdict.confidence,
    )


# Обратная совместимость: прежнее имя fallback теперь ведёт в AEGIS.
def _heuristic_fallback(ctx: SuspicionContext) -> SuspicionAssessment:
    return _aegis_assess(ctx, source="aegis")


def _parse_hour(local_time: str) -> Optional[int]:
    try:
        return int(local_time.split(":")[0])
    except (ValueError, IndexError, AttributeError):
        return None


def _parse_assessment(content: str, ctx: SuspicionContext) -> SuspicionAssessment:
    """Парсит JSON из ответа модели; при провале — fallback."""
    text = content.strip()
    # Модели иногда оборачивают JSON в ```...```
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
    # Берём от первой { до последней }
    start, end = text.find("{"), text.rfind("}")
    if start != -1 and end != -1:
        text = text[start:end + 1]
    # Автономная база AEGIS: даёт голос/сигналы/действие даже поверх ответа
    # нейросети, а также страхует, если модель вернёт мусор.
    base = _aegis_assess(ctx, source="aegis")
    try:
        data = json.loads(text)
        suspicion = _clamp(int(data.get("suspicion", 0)))
        should_ask = bool(data.get("should_ask", suspicion >= 60))
        reason = str(data.get("reason", "")) or base.reason
        question = str(data.get("question", "")) or base.question
        # Итог — максимум осторожности: не занижаем оценку ниже автономной.
        merged = max(suspicion, base.suspicion)
        return SuspicionAssessment(
            suspicion=merged,
            reason=reason,
            should_ask=should_ask or merged >= 60,
            question=question if (should_ask or merged >= 60) else "",
            source="aegis+llm",
            voice=base.voice,
            action=base.action,
            signals=base.signals,
            confidence=max(base.confidence, 70),
        )
    except (json.JSONDecodeError, ValueError, TypeError):
        return base


async def analyze_suspicion(
    ctx: SuspicionContext,
    api_key: Optional[str] = None,
    model: Optional[str] = None,
    timeout: float = 20.0,
) -> SuspicionAssessment:
    """Главная точка входа: оценить уровень подозрения по контексту.

    Мозг работает ВСЕГДА. Базовое рассуждение делает автономный AEGIS; если
    рядом доступна нейросеть — её ответ подмешивается как второе мнение
    (source="aegis+llm"). При отсутствии/сбое нейросети остаёмся на AEGIS
    (source="aegis") — без исключений и без «слепоты».
    """
    content = await _chat_completion(SYSTEM_PROMPT, ctx.to_prompt(), timeout)
    if content is None:
        return _aegis_assess(ctx, source="aegis")
    return _parse_assessment(content, ctx)


# ── Мед-анализ состояния ─────────────────────────────────────────

HEALTH_SYSTEM_PROMPT = (
    "Ты — O.R.I.O.N., ассистент по благополучию. По данным о состоянии "
    "пользователя (активность, вес, сон, настроение, стресс, БАДы, анализы) "
    "дай краткую оценку общего самочувствия по шкале 0..100 (выше — лучше) и "
    "практичные рекомендации. Ты НЕ ставишь диагнозов и не заменяешь врача; "
    "при тревожных признаках советуй обратиться к специалисту.\n"
    "Отвечай СТРОГО одним JSON-объектом без markdown, поля:\n"
    '{"score": <int 0..100>, "summary": "<2-3 предложения по-русски>", '
    '"recommendations": ["<совет>", "<совет>"]}'
)


@dataclass
class HealthAssessment:
    """Вердикт мед-анализа. Совпадает с iOS HealthAssessment."""
    score: int
    summary: str
    recommendations: list
    source: str = "aegis"
    # Считает только AEGIS: скринеры и тренды — арифметика по журналу,
    # доверять её нейросети незачем, а сверять клиенту нужно всегда.
    screens: dict = field(default_factory=dict)
    trends: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "score": self.score,
            "summary": self.summary,
            "recommendations": self.recommendations,
            "source": self.source,
            "screens": self.screens,
            "trends": self.trends,
        }


def _health_aegis(health: dict, source: str = "aegis") -> HealthAssessment:
    """Автономный мед-анализ через AEGIS. Работает всегда, без нейросети."""
    v = aegis.assess_health(health)
    return HealthAssessment(
        score=v["score"],
        summary=v["summary"],
        recommendations=v["recommendations"],
        source=source,
        screens=v.get("screens", {}),
        trends=v.get("trends", {}),
    )


# Обратная совместимость: прежнее имя теперь ведёт в AEGIS.
def _health_fallback(health: Optional[dict] = None) -> HealthAssessment:
    return _health_aegis(health or {}, source="aegis")


def _parse_health(content: str) -> HealthAssessment:
    text = content.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:]
    start, end = text.find("{"), text.rfind("}")
    if start != -1 and end != -1:
        text = text[start:end + 1]
    try:
        data = json.loads(text)
        recs = data.get("recommendations", [])
        if not isinstance(recs, list):
            recs = [str(recs)]
        return HealthAssessment(
            score=_clamp(int(data.get("score", 50))),
            summary=str(data.get("summary", "")) or "—",
            recommendations=[str(r) for r in recs],
            source="aegis+llm",
        )
    except (json.JSONDecodeError, ValueError, TypeError):
        return _health_fallback()


async def analyze_health(
    health: dict,
    api_key: Optional[str] = None,
    model: Optional[str] = None,
    timeout: float = 25.0,
) -> HealthAssessment:
    """Оценить состояние по словарю параметров. Мозг работает всегда:
    базовый разбор делает AEGIS (source="aegis"); при доступной нейросети
    её ответ используется как усиление (source="aegis+llm"). Без исключений."""
    # Превращаем словарь в человекочитаемый промпт
    lines = []
    labels = {
        "steps": "Шаги сегодня", "distance_km": "Дистанция, км",
        "weight_kg": "Вес, кг", "weight_trend_kg": "Тренд веса за месяц, кг",
        "mood": "Настроение (1..5)", "stress": "Стресс (1..5)",
        "sleep_hours": "Сон, ч", "supplements": "БАДы/приём", "note": "Заметка",
    }
    for key, label in labels.items():
        val = health.get(key)
        if val in (None, "", [], 0):
            continue
        if isinstance(val, list):
            val = ", ".join(str(v) for v in val)
        lines.append(f"{label}: {val}")
    # Скринеры считаем сами и кладём в промпт готовыми: модели незачем
    # складывать баллы, но знать про положительный PHQ-2 ей полезно.
    for key, s in aegis.screen_mental(health).items():
        verdict = "положительный" if s["positive"] else "отрицательный"
        lines.append(f"{key.upper()}: {s['score']}/{s['max']} — {verdict}")
    user_prompt = "\n".join(lines) if lines else "Нет данных."

    content = await _chat_completion(HEALTH_SYSTEM_PROMPT, user_prompt, timeout)
    if content is None:
        return _health_aegis(health, source="aegis")
    verdict = _parse_health(content)
    # Скринеры и тренды приживляем от AEGIS: нейросеть про них не спрашивали,
    # а терять их из-за того, что ответила модель, нельзя.
    base = _health_aegis(health)
    verdict.screens, verdict.trends = base.screens, base.trends
    return verdict
