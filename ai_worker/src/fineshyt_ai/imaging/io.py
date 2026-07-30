"""Image opening — RAW via rawpy when available, Pillow for everything else."""

from typing import BinaryIO

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


def open_as_pil(fp: BinaryIO, ext: str) -> Image.Image:
    """Open any supported image (RAW or PIL-native) and return an RGB `PIL.Image`.

    Takes a binary file-like object plus its extension (e.g. ".nef") rather
    than a filesystem path, so callers can stream bytes that never touch the
    container's filesystem — the orchestrator reads the source (which may live
    on a drive Docker can't bind-mount) and uploads the bytes here. Both
    rawpy.imread and PIL.Image.open accept file-like objects.
    """
    if ext in RAW_EXTS:
        if not _RAWPY_AVAILABLE:
            raise RuntimeError(f"rawpy not available — cannot open RAW file ({ext})")
        with rawpy.imread(fp) as raw:
            rgb = raw.postprocess(use_camera_wb=True, output_bps=8)
        return Image.fromarray(np.asarray(rgb))
    return Image.open(fp).convert("RGB")


def is_rawpy_available() -> bool:
    return _RAWPY_AVAILABLE
