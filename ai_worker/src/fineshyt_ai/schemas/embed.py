"""CLIP embedding I/O."""

from pydantic import BaseModel


class EmbedResponse(BaseModel):
    embedding: list[float]
    model: str
    dim: int
