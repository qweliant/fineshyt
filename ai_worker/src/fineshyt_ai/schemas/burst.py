"""Burst / sequence detection I/O."""

from pydantic import BaseModel, Field


class BurstPhotoInput(BaseModel):
    id: int
    embedding: list[float]
    sharpness_score: int = 0
    captured_at: str | None = None


class BurstDetectRequest(BaseModel):
    photos: list[BurstPhotoInput]
    similarity_threshold: float = Field(default=0.95, ge=0.8, le=1.0)
    max_time_gap_seconds: float = Field(default=5.0, ge=0.0, le=300.0)


class BurstGroup(BaseModel):
    group_id: int
    photo_ids: list[int]
    best_pick_id: int
    best_pick_sharpness: int
    size: int


class BurstDetectResponse(BaseModel):
    groups: list[BurstGroup]
    n_singletons: int
