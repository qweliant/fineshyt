"""Ridge preference-model train + score, in terms of Pydantic schemas."""

from datetime import datetime, timezone

import numpy as np

from fineshyt_ai.config import logger
from fineshyt_ai.models import preference as pref_model
from fineshyt_ai.schemas.preference import (
    PreferenceSample,
    PreferenceScoreResponse,
    PreferenceTrainResponse,
)


class NotEnoughSamplesError(ValueError):
    """Raised when a train call arrives with fewer labels than `min_samples`.

    Transport layer translates to HTTP 400 so the Elixir worker can
    log-and-skip without incrementing the version.
    """

    def __init__(self, n_samples: int, min_samples: int):
        super().__init__(f"need >= {min_samples} samples, got {n_samples}")
        self.n_samples = n_samples
        self.min_samples = min_samples


class NoModelTrainedError(RuntimeError):
    """Raised on a score call when no model has been trained yet."""


def train(samples: list[PreferenceSample], min_samples: int) -> PreferenceTrainResponse:
    """Fit Ridge on `samples`, persist, return the new version metadata."""
    if len(samples) < min_samples:
        raise NotEnoughSamplesError(len(samples), min_samples)

    X = np.asarray([s.embedding for s in samples], dtype=np.float32)
    y = np.asarray([s.rating for s in samples], dtype=np.float32)

    model, scaler, train_r2 = pref_model.fit(X, y)
    version = pref_model.next_version()
    pref_model.save(model, scaler, version)

    logger.info(
        "Trained preference model version=%s n_samples=%d train_r2=%.4f",
        version, len(samples), train_r2,
    )
    return PreferenceTrainResponse(
        model_version=version,
        n_samples=len(samples),
        train_r2=train_r2,
        trained_at=datetime.now(timezone.utc).isoformat(),
    )


def score(embeddings: list[list[float]]) -> PreferenceScoreResponse:
    """Score a batch of embeddings against the current model."""
    if pref_model.load() is None:
        raise NoModelTrainedError("no preference model trained yet")

    X = np.asarray(embeddings, dtype=np.float32)
    scores, version = pref_model.predict(X)
    return PreferenceScoreResponse(scores=scores, model_version=version)
