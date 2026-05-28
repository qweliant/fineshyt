"""EXIF DateTimeOriginal extraction. Must run on the source before conversion strips it."""

from datetime import datetime
from typing import BinaryIO

from PIL import Image

from fineshyt_ai.imaging.io import RAW_EXTS


def extract_captured_at(fp: BinaryIO, ext: str) -> str | None:
    """Read EXIF DateTimeOriginal, return ISO-8601 or None.

    Takes a binary file-like object plus its extension rather than a path,
    so the source bytes can be streamed in without touching the container's
    filesystem. Returns None silently on any failure — missing EXIF is
    common and never fatal. RAW files are skipped because rawpy does not
    expose EXIF directly (this is an open TODO — see `exiftool` as a fallback).
    """
    try:
        if ext in RAW_EXTS:
            return None
        img = Image.open(fp)
        exif = img.getexif()
        # Tag 36867 = DateTimeOriginal, tag 306 = DateTime (fallback).
        raw_dt = exif.get(36867) or exif.get(306)
        if not raw_dt or not isinstance(raw_dt, str):
            return None
        dt = datetime.strptime(raw_dt.strip(), "%Y:%m:%d %H:%M:%S")
        return dt.isoformat()
    except Exception:
        return None
