"""
╔══════════════════════════════════════════════════════╗
║  O.R.I.O.N. DEV  —  Ngrok версия для разработки      ║
║  Запуск с ngrok на порту 8080                        ║
╚══════════════════════════════════════════════════════╝
"""

import subprocess
import sys
import time
import os

def check_ngrok():
    """Проверка установки ngrok."""
    try:
        subprocess.run(["ngrok", "version"], capture_output=True, check=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

def start_ngrok(port=8080):
    """Запуск ngrok туннеля."""
    print(f"🚀 Запуск ngrok на порту {port}...")
    ngrok_process = subprocess.Popen(
        ["ngrok", "http", str(port)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    time.sleep(2)
    print("✅ Ngrok запущен")
    print("📡 Откройте http://127.0.0.1:4040 для просмотра ngrok dashboard")
    return ngrok_process

def start_server(port=8080):
    """Запуск FastAPI сервера."""
    print(f"🚀 Запуск O.R.I.O.N. Core на порту {port}...")
    server_process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "core.main:app",
         "--host", "0.0.0.0", "--port", str(port), "--reload"],
        cwd=os.path.dirname(os.path.abspath(__file__))
    )
    return server_process

def main():
    PORT = 8080

    print("╔══════════════════════════════════════════════════════╗")
    print("║  O.R.I.O.N. Development Server with Ngrok            ║")
    print("╚══════════════════════════════════════════════════════╝\n")

    if not check_ngrok():
        print("❌ Ngrok не установлен!")
        print("📥 Установите ngrok: https://ngrok.com/download")
        print("   или через: brew install ngrok (macOS)")
        print("   или через: choco install ngrok (Windows)")
        sys.exit(1)

    ngrok_proc = None
    server_proc = None

    try:
        # Запуск ngrok
        ngrok_proc = start_ngrok(PORT)

        # Запуск сервера
        server_proc = start_server(PORT)

        print("\n✅ Система запущена!")
        print(f"🌐 Локальный доступ: http://localhost:{PORT}")
        print(f"🌍 Ngrok dashboard: http://127.0.0.1:4040")
        print(f"📱 Используйте ngrok URL в iOS приложении")
        print("\n⚠️  Нажмите Ctrl+C для остановки\n")

        # Ожидание
        while True:
            time.sleep(1)

    except KeyboardInterrupt:
        print("\n\n🛑 Остановка сервисов...")

    finally:
        if server_proc:
            server_proc.terminate()
            server_proc.wait()
            print("✅ Сервер остановлен")

        if ngrok_proc:
            ngrok_proc.terminate()
            ngrok_proc.wait()
            print("✅ Ngrok остановлен")

        print("\n👋 До встречи!")

if __name__ == "__main__":
    main()
