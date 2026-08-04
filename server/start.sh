#!/usr/bin/env bash
# Запуск на Render: core + бот в одном процессе (free-тариф = один сервис).
set -e

# Бот ходит в core по локальному адресу того же контейнера.
export CORE_URL="http://127.0.0.1:${PORT:-8080}"

# Бот — только если токен реально задан (не плейсхолдер из .env.example).
# Health-check Render видит только core, поэтому упавшего бота перезапускаем сами.
if [ -n "${TELEGRAM_TOKEN:-}" ] && [ "${TELEGRAM_TOKEN}" != "your-telegram-bot-token-here" ]; then
    (
        sleep 5
        while true; do
            python bot.py || true
            echo "bot.py упал, перезапуск через 10с..." >&2
            sleep 10
        done
    ) &
fi

exec uvicorn core.main:app --host 0.0.0.0 --port "${PORT:-8080}"
