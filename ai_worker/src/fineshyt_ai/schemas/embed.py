"""CLIP embedding I/O."""

from pydantic import BaseModel


class EmbedRequest(BaseModel):
    file_path: str


class EmbedResponse(BaseModel):
    embedding: list[float]
    model: str
    dim: int
