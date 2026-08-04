# O.R.I.O.N. Core — образ сервера (+ опциональная сборка C++ ядра)
FROM python:3.11-slim

WORKDIR /app

# Тулчейн для сборки нативного каскадного шифра (ускоряет /secure/ingest).
# Если не нужен — можно убрать build-essential/cmake и ONBUILD-шаг ниже,
# сервер всё равно работает на чистом Python.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY core/ ./core/
COPY templates/ ./templates/
COPY bot.py .

# Собираем C++ ядро (не критично: при неудаче падаем на Python-реализацию).
RUN cmake -S core/native -B core/native/build \
    && cmake --build core/native/build --config Release \
    && ctest --test-dir core/native/build --output-on-failure \
    || echo "[build] нативное ядро не собрано — используется Python-реализация"

EXPOSE 8000

CMD ["uvicorn", "core.main:app", "--host", "0.0.0.0", "--port", "8000"]
