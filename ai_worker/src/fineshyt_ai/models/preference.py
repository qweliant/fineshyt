"""Pickled Ridge + StandardScaler preference model with mtime-tracked cache.

Pure functions on numpy arrays — no HTTP, no schemas. The domain layer
wraps these with the Pydantic contract. The cache invalidates off file
mtime so a train in one process picks up in another without a restart.
"""

import pickle
import threading
from typing import Any

import numpy as np

from fineshyt_ai.config import (
    CLIP_EMBED_DIM,
    CLIP_MODEL_NAME,
    FINESHYT_MODEL_DIR,
    PREFERENCE_MODEL_PATH,
    logger,
)

_state: dict[str, Any] = {"model": None, "scaler": None, "version": 0, "mtime": 0.0}
_lock = threading.Lock()


def load() -> dict[str, Any] | None:
    """Return the current `{model, scaler, version}` or None if never trained.

    Reloads from disk whenever the pickle's mtime has changed.
    """
    if not PREFERENCE_MODEL_PATH.exists():
        return None

    mtime = PREFERENCE_MODEL_PATH.stat().st_mtime
    with _lock:
        if _state["model"] is not None and mtime == _state["mtime"]:
            return _state

        with open(PREFERENCE_MODEL_PATH, "rb") as f:
            payload = pickle.load(f)
        _state["model"] = payload["model"]
        _state["scaler"] = payload["scaler"]
        _state["version"] = payload["version"]
        _state["mtime"] = mtime
        logger.info("Loaded preference model version=%s", payload["version"])
        return _state


def fit(embeddings: np.ndarray, ratings: np.ndarray):
    """Fit StandardScaler + Ridge(alpha=1.0), return `(model, scaler, train_r2)`."""
    from sklearn.linear_model import Ridge
    from sklearn.preprocessing import StandardScaler

    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(embeddings)

    model = Ridge(alpha=1.0)
    model.fit(X_scaled, ratings)
    return model, scaler, float(model.score(X_scaled, ratings))


def save(model, scaler, version: int) -> None:
    """Pickle `{model, scaler, version, clip_model, embed_dim}` and refresh cache."""
    FINESHYT_MODEL_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "model": model,
        "scaler": scaler,
        "version": version,
        "clip_model": CLIP_MODEL_NAME,
        "embed_dim": CLIP_EMBED_DIM,
    }
    with open(PREFERENCE_MODEL_PATH, "wb") as f:
        pickle.dump(payload, f)

    with _lock:
        _state["model"] = model
        _state["scaler"] = scaler
        _state["version"] = version
        _state["mtime"] = PREFERENCE_MODEL_PATH.stat().st_mtime


def next_version() -> int:
    """Return the version integer that a fresh train should claim."""
    prev = load()
    return (prev["version"] if prev else 0) + 1


def predict(embeddings: np.ndarray) -> tuple[list[int], int]:
    """Score `embeddings` against the current model. Raises if none trained.

    Returns `(scores_0_to_100, version)`. Ridge predicts in the 1..5 rating
    space; we linearly map that to 0..100 and clip.
    """
    state = load()
    if state is None:
        raise RuntimeError("no preference model trained yet")

    X_scaled = state["scaler"].transform(embeddings)
    preds = state["model"].predict(X_scaled)
    scores = np.clip(np.round((preds - 1.0) * 25.0), 0, 100).astype(int).tolist()
    return scores, state["version"]
