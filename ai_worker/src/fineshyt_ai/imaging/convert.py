"""Long-edge resize + unique-path allocation for the conversion pipeline."""

from pathlib import Path

from PIL import Image


def resize_to_long_edge(img: Image.Image, long_edge: int) -> Image.Image:
    """Resize so the longer edge equals `long_edge`, preserving aspect ratio."""
    w, h = img.size
    if max(w, h) <= long_edge:
        return img
    if w >= h:
        return img.resize((long_edge, round(h * long_edge / w)), Image.LANCZOS)
    return img.resize((round(w * long_edge / h), long_edge), Image.LANCZOS)


def unique_output_path(uploads_dir: Path, stem: str) -> Path:
    """Return a non-colliding `<stem>.jpg` path, suffixing `_N` on collision."""
    out = uploads_dir / f"{stem}.jpg"
    counter = 1
    while out.exists():
        out = uploads_dir / f"{stem}_{counter}.jpg"
        counter += 1
    return out
