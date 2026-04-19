"""Exception → HTTP status + structured error-payload translation.

The Elixir orchestrator consumes these payloads in
`Orchestrator.Workers.AiCurationWorker.format_api_error/1` and surfaces
them on `/logs`, so the shape is a contract — don't reshape casually.

Called ONLY at transport boundaries (`transports/http/routes/*`). Domain
functions raise plain exceptions; the route layer decides what that
becomes on the wire.
"""

import traceback
from typing import Any

from openai import APIError

from fineshyt_ai.config import logger


def status_for(exc: Exception) -> int:
    """Map an exception to an HTTP status code.

    Unwraps `openai.APIError` so upstream Ollama/Claude codes reach the
    Elixir caller intact instead of collapsing to 500. Ollama follows
    standard HTTP semantics (400 invalid, 404 model-not-found, 413
    payload-too-large, 429 rate-limited, 499 client-closed, 500 server,
    503 unavailable).
    """
    if isinstance(exc, APIError):
        status = getattr(exc, "status_code", None)
        if isinstance(status, int) and 400 <= status < 600:
            return status
    return 500


def error_detail(op: str, exc: Exception, **context: Any) -> dict[str, Any]:
    """Build a structured error payload and log the full traceback.

    Shape is stable: `{op, error_type, message, context, upstream?}`.
    The Elixir side parses this to show a real reason in the gallery
    and on `/logs` instead of a bare HTTP status.
    """
    exc_type = type(exc).__name__
    message = str(exc) or exc_type

    upstream: dict[str, Any] = {}
    if isinstance(exc, APIError):
        upstream["status_code"] = getattr(exc, "status_code", None)
        upstream["code"] = getattr(exc, "code", None)
        upstream["message"] = getattr(exc, "message", None)
        body = getattr(exc, "body", None)
        if body is not None:
            upstream["body"] = body

    payload: dict[str, Any] = {
        "op": op,
        "error_type": exc_type,
        "message": message,
        "context": context,
    }
    if upstream:
        payload["upstream"] = upstream

    logger.error(
        "operation=%s failed: %s: %s | context=%s | upstream=%s\n%s",
        op,
        exc_type,
        message,
        context,
        upstream or None,
        traceback.format_exc(),
    )
    return payload
