# FastAPI Chat Stub (HTML + JavaScript)

Минимальный стек: **FastAPI** обслуживает API и статику (без React/сборщиков).
Работает на **HTTPS** `https://127.0.0.1:8240` (самоподписанный сертификат).

## Запуск (WSL/Ubuntu/macOS)

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# один раз сгенерировать TLS-сертификат
./scripts/gen-cert.sh

# запуск uvicorn под HTTPS
./scripts/run-https.sh
```

Открой в браузере: https://127.0.0.1:8240 (прими предупреждение о самоподписанном сертификате).

## Структура
- `app/main.py` — FastAPI, статика, заглушки `/api/chat` и `/api/chat/stream` (SSE).
- `static/index.html`, `static/app.js` — фронт (HTML + JS).
- `.vscode/launch.json` + `.vscode/tasks.json` — запуск из VSCode: **Run → Start Debugging**.
- `scripts/gen-cert.sh` — генерация самоподписанного сертификата.
- `scripts/run-https.sh` — запуск uvicorn с TLS.
- `requirements.txt`

## Подключение реального бэка
Замените выборку ответа в `choose_sample()` на реальные вызовы (локальный LLM/HTTP). Контракт фронта менять не нужно.

Если хотите включить реальную работу с базой данных (репозитории в `app/db`):

- Установите зависимости SQLAlchemy и драйвер Postgres (пример):

```bash
pip install sqlalchemy psycopg2-binary
```

- При старте приложение попытается лениво импортировать `app.db.db` в `@app.on_event('startup')` и положит репозитории в `app.state.repos`.
- Если зависимости отсутствуют, приложение стартует, но в логах будет предупреждение: `DB dependencies not installed — DB features disabled.`

После установки зависимостей перезапустите сервер и убедитесь, что в логах появится `DB repositories loaded and attached to app.state`.
