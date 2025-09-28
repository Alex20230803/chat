import logging
from typing import Any, Dict

SAMPLES: Dict[str, str] = {
    "code": "Вот пример функции на Python, которая вычисляет факториал:\n\n```python\ndef factorial(n):\n    if n < 2: return 1\n    return n * factorial(n-1)\n```\n\nСовет: для больших n используйте math.prod(range(1, n+1)).",
    "sql": "Пример запроса: SELECT id, title FROM tasks WHERE status = 'open' ORDER BY created_at DESC LIMIT 25;\n\nПодумайте о покрытии индексацией (status, created_at).",
    "default": "Привет! Это заглушка ✨ Я симулирую ответ модели. Можем подключить реальные вызовы позже — точки расширения уже есть.",
}


def choose_sample(prompt: str) -> str:
    """Select a sample response or query DB/LLM as needed.

    This function intentionally uses ``fastapi.current_app`` to access
    ``app.state`` so it can be imported from ``app.main`` without
    creating circular imports.
    """
    logger = logging.getLogger("chatstub")
    logger.info("prompt: %s", prompt)

    # Attempt to retrieve LLMS list result for inclusion in the assistant
    # response when the repo is available. We keep the operation best-effort
    # (do not fail the whole function if DB deps are missing).
    llms_result = None
    try:
        # Import app at runtime to avoid circular imports and to access
        # the application state (repositories) populated at startup.
        from app.main import app as main_app
        repos = getattr(main_app.state, "repos", None)
        if repos and "LLMS" in repos:
            llms_result = repos["LLMS"].list(llm_name="AMD QWEN", limit=5)
            logger.info("LLMS.list result: %s", llms_result)
        else:
            logger.info("LLMS repo not available in app.state.repos")
    except Exception:
        logger.exception("error while listing LLMS for debug")

    p = (prompt or "").lower()
    if "sql" in p:
        return SAMPLES["sql"]
    if "код" in p or "code" in p:
        return SAMPLES["code"]
    else:
        body = f"Пумп:{prompt}"
        if llms_result:
            # Append a small, human-readable summary of the LLMS repo result so
            # the UI can show repository contents inside the assistant message.
            try:
                summary_lines = []
                for row in llms_result:
                    # Prefer readable fields if present
                    name = row.get("llm_name") or row.get("name") or "<unnamed>"
                    model = row.get("llm_model") or row.get("model") or "<model>"
                    summary_lines.append(f"{name} ({model})")
                body += "\n\nLLMS repo results:\n- " + "\n- ".join(summary_lines)
            except Exception:
                # If result is not a list of dicts, just append its repr
                body += "\n\nLLMS repo results: " + repr(llms_result)
        return body
    return SAMPLES["default"]
