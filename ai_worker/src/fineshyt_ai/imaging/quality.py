"""Sharpness + exposure scoring. Run on full-resolution pixels, not the 1440 JPEG."""

import numpy as np
from PIL import Image

# Scoring is done on a downsampled grayscale copy so the numbers are
# comparable across source resolutions (a 45MP RAW and a 12MP JPEG should
# land in the same range for the same scene).
_SCORE_LONG_EDGE = 1024


def _score_downsample(img: Image.Image) -> np.ndarray:
    """Convert to grayscale, downsample to _SCORE_LONG_EDGE, return float32."""
    gray = img.convert("L")
    w, h = gray.size
    if max(w, h) > _SCORE_LONG_EDGE:
        if w >= h:
            gray = gray.resize(
                (_SCORE_LONG_EDGE, round(h * _SCORE_LONG_EDGE / w)), Image.BILINEAR
            )
        else:
            gray = gray.resize(
                (round(w * _SCORE_LONG_EDGE / h), _SCORE_LONG_EDGE), Image.BILINEAR
            )
    return np.asarray(gray, dtype=np.float32)


def sharpness_score(gray: np.ndarray) -> int:
    """Variance-of-Laplacian sharpness, normalized to 0..100.

    The 300.0 divisor puts typical in-focus photos in the 70-100 range and
    clearly blurry shots under 30. Retune against real numbers.
    """
    c = gray[1:-1, 1:-1]
    lap = 4.0 * c - gray[:-2, 1:-1] - gray[2:, 1:-1] - gray[1:-1, :-2] - gray[1:-1, 2:]
    var = float(lap.var())
    return int(round(min(var / 300.0, 1.0) * 100))


def exposure_score(gray: np.ndarray) -> int:
    """Penalize histogram clipping at the black and white points.

    Counts pixels within 5 levels of either endpoint — JPEG quantization
    and scene noise mean truly crushed/blown regions cluster near 0/255
    rather than landing exactly on them. 0.5% combined clipped is free;
    the score falls linearly to 0 at 5% clipped.
    """
    total = gray.size
    clipped = float(((gray <= 5.0) | (gray >= 250.0)).sum()) / total
    if clipped <= 0.005:
        return 100
    if clipped >= 0.05:
        return 0
    return int(round((1.0 - (clipped - 0.005) / 0.045) * 100))


def compute_quality_scores(img: Image.Image) -> dict[str, int]:
    """Compute sharpness, exposure, and a weighted overall score.

    Weights: 0.7 sharpness + 0.3 exposure — blur is usually a harder cull
    than mild clipping. Retune against real data.
    """
    gray = _score_downsample(img)
    sharp = sharpness_score(gray)
    exp = exposure_score(gray)
    overall = int(round(0.7 * sharp + 0.3 * exp))
    return {"sharpness": sharp, "exposure": exp, "overall": overall}
