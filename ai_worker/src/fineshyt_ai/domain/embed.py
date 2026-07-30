"""Single-image CLIP embedding."""

from io import BytesIO
from pathlib import Path

from fineshyt_ai.config import CLIP_EMBED_DIM, CLIP_MODEL_NAME
from fineshyt_ai.models.clip import embed_image
from fineshyt_ai.schemas.embed import EmbedResponse


def embed(data: bytes, filename: str) -> EmbedResponse:
    """Return a 768-dim L2-normalized CLIP embedding for the uploaded image.

    Takes the image bytes + original filename (uploaded by the orchestrator)
    rather than a path, so the file never needs to be readable from inside
    this container.
    """
    ext = Path(filename).suffix.lower()
    vec = embed_image(BytesIO(data), ext)
    return EmbedResponse(embedding=vec, model=CLIP_MODEL_NAME, dim=CLIP_EMBED_DIM)
