"""Conversion pipeline — source file → resized JPEG + quality scores + EXIF.

Also exposes the narrower `quality_scores` and `exif` operations used by
backfill tasks.
"""

from pathlib import Path

from fineshyt_ai.config import STATIC_UPLOADS_DIR
from fineshyt_ai.imaging.convert import resize_to_long_edge, unique_output_path
from fineshyt_ai.imaging.exif import extract_captured_at
from fineshyt_ai.imaging.io import open_as_pil
from fineshyt_ai.imaging.quality import compute_quality_scores
from fineshyt_ai.schemas.convert import ConvertResponse, ExifResponse, QualityScoresResponse


def convert(path: Path) -> ConvertResponse:
    """Open → score → resize → write JPEG → return the new path + scores.

    Quality scoring runs on the full-resolution source before downsize —
    the 1440 JPEG has already lost the high-frequency detail that
    sharpness relies on. EXIF is read from the source too, before
    conversion strips it.
    """
    captured_at = extract_captured_at(path)
    img = open_as_pil(path)
    scores = compute_quality_scores(img)
    img = resize_to_long_edge(img, 1440)

    STATIC_UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    out = unique_output_path(STATIC_UPLOADS_DIR, path.stem)
    img.save(out, "JPEG", quality=82, optimize=True)

    return ConvertResponse(
        jpeg_path=str(out),
        technical_score=scores["overall"],
        sharpness_score=scores["sharpness"],
        exposure_score=scores["exposure"],
        captured_at=captured_at,
    )


def exif(path: Path) -> ExifResponse:
    """Read EXIF DateTimeOriginal from `path` — used by the backfill task."""
    return ExifResponse(captured_at=extract_captured_at(path))


def quality_scores(path: Path) -> QualityScoresResponse:
    """Compute technical scores from `path` — used by the backfill task."""
    img = open_as_pil(path)
    scores = compute_quality_scores(img)
    return QualityScoresResponse(
        technical_score=scores["overall"],
        sharpness_score=scores["sharpness"],
        exposure_score=scores["exposure"],
    )
