"""LLM curation I/O schema — the contract returned by /api/v1/curate."""

from typing import Annotated, Any

from pydantic import BaseModel, BeforeValidator, Field

VALID_CONTENT_TYPES = {
    "portrait", "street", "family", "landscape",
    "still_life", "architecture", "abstract", "other",
}


def coerce_content_type(v: Any) -> str:
    """Force invalid LLM outputs into the 'other' category.

    The prompt lists the valid categories, but LLaVA in particular will
    happily invent 'artwork' or 'interior'. Instructor's JSON mode
    validates the schema but not the domain, so we coerce here.
    """
    if isinstance(v, str):
        v_lower = v.lower().strip()
        if v_lower in VALID_CONTENT_TYPES:
            return v_lower
    return "other"


SafeContentType = Annotated[str, BeforeValidator(coerce_content_type)]


class PhotoMetadata(BaseModel):
    subject: str = Field(
        description=(
            "The primary subject of the photo. Be specific — describe what is actually depicted."
        )
    )
    content_type: SafeContentType = Field(
        description=(
            "The primary content category. Choose exactly one: "
            "'portrait' = single person, headshot, or environmental portrait; "
            "'street' = candid urban/public life, people in city environments; "
            "'family' = groups of people, gatherings, events, snapshots; "
            "'landscape' = outdoor scenery, nature, no dominant human subjects; "
            "'still_life' = objects, food, close-up of non-living things; "
            "'architecture' = buildings, interiors, urban structures; "
            "'abstract' = non-representational, heavy manipulation, or texture-focused; "
            "'other' = anything that doesn't fit the above."
        )
    )
    lighting_critique: str = Field(
        description="A brief, one-sentence critique of the lighting and contrast."
    )
    artistic_mood: str = Field(description="The emotional tone of the photo.")
    suggested_tags: list[str] = Field(
        description=(
            "5 to 7 specific tags describing technique, mood, or subject for a "
            "portfolio database. Do not include generic terms like 'photography' or 'photo'."
        )
    )
