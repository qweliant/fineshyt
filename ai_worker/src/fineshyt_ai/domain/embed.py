"""Single-image CLIP embedding."""

from pathlib import Path

from fineshyt_ai.config import CLIP_EMBED_DIM, CLIP_MODEL_NAME
from fineshyt_ai.models.clip import embed_image
from fineshyt_ai.schemas.embed import EmbedResponse


def embed(path: Path) -> EmbedResponse:
    """Return a 768-dim L2-normalized CLIP embedding for the file at `path`."""
    vec = embed_image(path)
    return EmbedResponse(embedding=vec, model=CLIP_MODEL_NAME, dim=CLIP_EMBED_DIM)
