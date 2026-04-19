"""Image opening — RAW via rawpy when available, Pillow for everything else."""

from pathlib import Path

import numpy as np
from PIL import Image

RAW_EXTS = {
    ".cr2", ".cr3", ".nef", ".arw", ".dng", ".raf", ".orf", ".rw2",
    ".pef", ".srw", ".x3f", ".3fr", ".erf", ".mef", ".mos", ".nrw", ".raw",
}

try:
    import rawpy
    _RAWPY_AVAILABLE = True
except ImportError:
    _RAWPY_AVAILABLE = False


def open_as_pil(path: Path) -> Image.Image:
    """Open any supported image (RAW or PIL-native) and return an RGB `PIL.Image`."""
    ext = path.suffix.lower()
    if ext in RAW_EXTS:
        if not _RAWPY_AVAILABLE:
            raise RuntimeError(f"rawpy not available — cannot open RAW file {path.name}")
        with rawpy.imread(str(path)) as raw:
            rgb = raw.postprocess(use_camera_wb=True, output_bps=8)
        return Image.fromarray(np.asarray(rgb))
    return Image.open(path).convert("RGB")


def is_rawpy_available() -> bool:
    return _RAWPY_AVAILABLE
