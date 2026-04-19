"""EXIF DateTimeOriginal extraction. Must run on the source before conversion strips it."""

from datetime import datetime
from pathlib import Path

from PIL import Image

from fineshyt_ai.imaging.io import RAW_EXTS, is_rawpy_available


def extract_captured_at(path: Path) -> str | None:
    """Read EXIF DateTimeOriginal, return ISO-8601 or None.

    Returns None silently on any failure — missing EXIF is common and
    never fatal. RAW files are skipped because rawpy does not expose EXIF
    directly (this is an open TODO — see `exiftool` as a fallback).
    """
    try:
        ext = path.suffix.lower()
        if ext in RAW_EXTS:
            if not is_rawpy_available():
                return None
            return None
        img = Image.open(path)
        exif = img.getexif()
        # Tag 36867 = DateTimeOriginal, tag 306 = DateTime (fallback).
        raw_dt = exif.get(36867) or exif.get(306)
        if not raw_dt or not isinstance(raw_dt, str):
            return None
        dt = datetime.strptime(raw_dt.strip(), "%Y:%m:%d %H:%M:%S")
        return dt.isoformat()
    except Exception:
        return None
