"""LLM curation — one photo in, `PhotoMetadata` out."""

from fineshyt_ai.models.llm import curate_image
from fineshyt_ai.schemas.curate import PhotoMetadata


async def curate(image_bytes: bytes, content_type: str) -> PhotoMetadata:
    """Validate the content-type and ask the LLM to fill `PhotoMetadata`.

    Raises:
        ValueError: if `content_type` isn't an `image/*` type.
        openai.APIError: on any upstream LLM failure (translated at the
            transport boundary).
    """
    if not content_type or not content_type.startswith("image/"):
        raise ValueError("File must be an image.")
    return await curate_image(image_bytes, content_type)
