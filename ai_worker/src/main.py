"""Entry point kept for backwards compatibility with `fastapi dev src/main.py`.

All logic lives in the `fineshyt_ai` package. This file just re-exports
the FastAPI app so the existing Makefile target keeps working.
"""

from fineshyt_ai.transports.http.app import app

__all__ = ["app"]
