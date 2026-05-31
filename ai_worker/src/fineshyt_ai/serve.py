"""Freezable entry point for the ai_worker.

`fastapi run` is a CLI wrapper that isn't suitable for ahead-of-time freezing
(Nuitka / PyInstaller), so this starts uvicorn directly against the same app.
Used by the C4 native-binary build; dev still uses `fastapi dev src/main.py`.
"""

import os


def main() -> None:
    import uvicorn

    from fineshyt_ai.transports.http.app import app

    host = os.getenv("AI_WORKER_HOST", "0.0.0.0")
    port = int(os.getenv("AI_WORKER_PORT", "8000"))
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    main()
