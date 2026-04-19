"""Preference model train/score I/O — the Ridge linear-probe contract."""

from pydantic import BaseModel, Field


class PreferenceSample(BaseModel):
    embedding: list[float]
    rating: int = Field(ge=1, le=5)


class PreferenceTrainRequest(BaseModel):
    samples: list[PreferenceSample]
    min_samples: int = 20


class PreferenceTrainResponse(BaseModel):
    model_version: int
    n_samples: int
    train_r2: float
    trained_at: str


class PreferenceScoreRequest(BaseModel):
    embeddings: list[list[float]]


class PreferenceScoreResponse(BaseModel):
    scores: list[int]
    model_version: int
