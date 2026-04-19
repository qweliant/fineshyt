"""Instructor-wrapped OpenAI-compatible client + the one completion we run.

Caller passes raw image bytes + content-type; this module handles base64
encoding, the multimodal messages payload, and structured-output coercion
into `PhotoMetadata` via instructor. It knows nothing about HTTP or
FastAPI — a RabbitMQ consumer calls `curate_image(bytes, content_type)`
the same way a route does.
"""

import base64

import instructor
from openai import AsyncOpenAI

from fineshyt_ai.config import LLM_API_KEY, LLM_BASE_URL, LLM_MODEL
from fineshyt_ai.schemas.curate import PhotoMetadata

_CURATION_PROMPT = (
    "You are an expert photo curator. Analyze this photograph and extract the metadata. "
    "Be accurate about content_type — most photos are of people (portrait, family, street). "
    "Only use 'still_life' for photos where objects are the clear, intentional subject "
    "with no people present. "
    "Only use 'abstract' for photos that are genuinely non-representational.\n"
    "CRITICAL: For content_type, you MUST choose from the exact provided list. "
    "DO NOT invent new categories like 'artwork' or 'interior'. If unsure, choose 'other'."
)


client = instructor.from_openai(
    AsyncOpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY),
    mode=instructor.Mode.JSON,
)


async def curate_image(image_bytes: bytes, content_type: str) -> PhotoMetadata:
    """Call the vision LLM and coerce its reply into `PhotoMetadata`.

    `instructor` retries up to 3 times on schema-validation failures, but
    won't shield against upstream errors (network, 429, 503, etc.) — those
    propagate as `openai.APIError` subclasses and are translated at the
    transport boundary.
    """
    b64 = base64.b64encode(image_bytes).decode("utf-8")
    return await client.chat.completions.create(
        model=LLM_MODEL,
        response_model=PhotoMetadata,
        messages=[
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": _CURATION_PROMPT},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:{content_type};base64,{b64}"},
                    },
                ],
            }
        ],
        max_retries=3,
    )
