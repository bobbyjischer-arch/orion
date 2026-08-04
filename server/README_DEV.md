# O.R.I.O.N. Development Setup (Ngrok)

## Быстрый старт для разработки

### 1. Установите зависимости

```bash
pip install -r requirements.txt
```

### 2. Установите ngrok

- **macOS**: `brew install ngrok`
- **Windows**: `choco install ngrok` или скачайте с https://ngrok.com/download
- **Linux**: `snap install ngrok`

### 3. Настройте переменные окружения

Создайте `.env` файл:
```bash
TELEGRAM_TOKEN=your_bot_token_here
SECRET_CODE=0000
```

### 4. Запустите dev сервер с ngrok

```bash
python start_dev.py
```

Это запустит:
- FastAPI сервер на порту 8080
- Ngrok туннель для публичного доступа
- Ngrok dashboard на http://127.0.0.1:4040

### 5. Настройте iOS приложение

1. Откройте ngrok dashboard: http://127.0.0.1:4040
2. Скопируйте публичный URL (например: `https://abc123.ngrok.io`)
3. В iOS приложении (Settings) вставьте этот URL в поле "URL сервера"

### 6. Запустите Telegram бота (опционально)

В отдельном терминале:
```bash
export CORE_URL=https://your-ngrok-url.ngrok.io
python bot.py
```

## Структура проекта

```
orion_final/
├── core/
│   └── main.py          # FastAPI сервер
├── templates/
│   └── index.html       # Web dashboard
├── bot.py               # Telegram бот
├── start_dev.py         # Dev launcher с ngrok
└── requirements.txt
```

## Endpoints

- `GET /` - Web dashboard
- `GET /api/status` - Статус системы
- `POST /location/update` - Обновление локации
- `POST /sos/trigger` - SOS сигнал
- `GET /events/stream` - SSE stream

## Отладка

- Ngrok dashboard: http://127.0.0.1:4040 (просмотр всех запросов)
- Локальный доступ: http://localhost:8080
- Логи сервера в терминале

## Остановка

Нажмите `Ctrl+C` для остановки всех сервисов.
