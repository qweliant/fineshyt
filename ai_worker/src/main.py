import base64
import os
import random
from pathlib import Path

import instructor
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from openai import AsyncOpenAI
from PIL import Image
from pydantic import BaseModel, Field

load_dotenv()

LLM_BASE_URL = os.getenv("LLM_BASE_URL", "http://localhost:11434/v1/")
LLM_API_KEY = os.getenv("LLM_API_KEY", "ollama")
LLM_MODEL = os.getenv("LLM_MODEL", "llava")
# Where converted JPEGs are written — must match orchestrator's priv/static/uploads/
STATIC_UPLOADS_DIR = os.getenv("STATIC_UPLOADS_DIR", "/tmp/fineshyt_uploads")

client = instructor.from_openai(
    AsyncOpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY),
    mode=instructor.Mode.JSON,
)

app = FastAPI(title="Fineshyt Photo Curation API")


class PhotoMetadata(BaseModel):
    subject: str = Field(description="The primary subject of the photo.")
    is_macro: bool = Field(
        description="True if the photo appears to be a macro or extreme close-up shot."
    )
    lighting_critique: str = Field(
        description="A brief, one-sentence critique of the lighting and contrast."
    )
    artistic_mood: str = Field(description="The emotional tone of the photo.")
    suggested_tags: list[str] = Field(description="5 to 7 specific tags for a portfolio database.")
    style_match: bool = Field(
        description="True if the photo matches the provided style description. False if no style description was given."
    )
    style_score: int = Field(
        description="Style match confidence from 0 to 100. 0 if no style description was given."
    )
    style_reason: str = Field(
        description="One sentence explaining the style match decision. Empty string if no style description was given."
    )


class LocalIngestRequest(BaseModel):
    dir_path: str
    sample: int | None = None


class LocalIngestResponse(BaseModel):
    file_paths: list[str]
    total_found: int


@app.post("/api/v1/curate", response_model=PhotoMetadata, tags=["Agent Workflow"])
async def curate_photo(
    file: UploadFile = File(...),
    style_description: str = Form(""),
):
    if not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="File must be an image.")

    image_bytes = await file.read()
    base64_image = base64.b64encode(image_bytes).decode("utf-8")

    if style_description:
        style_prompt = f"""
The photographer's style is described as:
"{style_description}"

Evaluate whether this photograph matches that style. Be strict — only mark style_match: true
if the photo genuinely fits the described aesthetic. Set style_score (0-100) and style_reason accordingly.
"""
    else:
        style_prompt = "No style description provided. Set style_match: false, style_score: 0, style_reason: empty string."

    try:
        metadata = await client.chat.completions.create(
            model=LLM_MODEL,
            response_model=PhotoMetadata,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": f"You are an expert photo curator. Analyze this photograph and extract the metadata.\n\n{style_prompt}",
                        },
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:{file.content_type};base64,{base64_image}"},
                        },
                    ],
                }
            ],
            max_retries=3,
        )
        return metadata

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"AI Processing failed: {str(e)}")


# Formats Pillow can open natively
_PILLOW_EXTS = {".tif", ".tiff", ".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tga", ".psd"}

# Camera RAW formats — handled by rawpy if available
_RAW_EXTS = {".cr2", ".cr3", ".nef", ".arw", ".dng", ".raf", ".orf", ".rw2", ".pef", ".srw", ".x3f", ".3fr", ".erf", ".mef", ".mos", ".nrw", ".raw"}

_ALL_EXTS = _PILLOW_EXTS | _RAW_EXTS

try:
    import rawpy
    import numpy as np
    _RAWPY_AVAILABLE = True
except ImportError:
    _RAWPY_AVAILABLE = False


def _open_as_pil(path: Path) -> Image.Image:
    """Open any supported image file and return an RGB PIL Image."""
    ext = path.suffix.lower()
    if ext in _RAW_EXTS:
        if not _RAWPY_AVAILABLE:
            raise RuntimeError(f"rawpy not available — cannot open RAW file {path.name}")
        with rawpy.imread(str(path)) as raw:
            rgb = raw.postprocess(use_camera_wb=True, output_bps=8)
        return Image.fromarray(np.asarray(rgb))
    else:
        return Image.open(path).convert("RGB")


def _resize_to_long_edge(img: Image.Image, long_edge: int) -> Image.Image:
    w, h = img.size
    if max(w, h) <= long_edge:
        return img
    if w >= h:
        return img.resize((long_edge, round(h * long_edge / w)), Image.LANCZOS)
    return img.resize((round(w * long_edge / h), long_edge), Image.LANCZOS)


def _unique_output_path(uploads_dir: Path, stem: str) -> Path:
    out = uploads_dir / f"{stem}.jpg"
    counter = 1
    while out.exists():
        out = uploads_dir / f"{stem}_{counter}.jpg"
        counter += 1
    return out


@app.post("/api/v1/ingest/local", response_model=LocalIngestResponse, tags=["Ingestion"])
def ingest_local(request: LocalIngestRequest):
    """Walk a local directory, find all supported image files (JPEG, TIFF, PNG, WebP,
    camera RAW, etc.), optionally random-sample N, convert to JPEG (1440px long edge,
    q=82), and save to the static uploads directory.
    Runs synchronously (FastAPI threadpool) — safe for large batches."""
    source_dir = Path(request.dir_path)
    if not source_dir.is_dir():
        raise HTTPException(status_code=400, detail=f"Directory not found: {request.dir_path}")

    image_files = [
        p for p in source_dir.rglob("*")
        if p.is_file()
        and not p.name.startswith(".")  # skip macOS ._sidecar and hidden files
        and p.suffix.lower() in _ALL_EXTS
    ]

    if not image_files:
        raise HTTPException(
            status_code=404,
            detail=f"No supported image files found in {request.dir_path}"
        )

    total_found = len(image_files)

    if request.sample is not None and request.sample < total_found:
        image_files = random.sample(image_files, request.sample)

    uploads_dir = Path(STATIC_UPLOADS_DIR)
    uploads_dir.mkdir(parents=True, exist_ok=True)

    file_paths = []
    for img_path in image_files:
        try:
            img = _open_as_pil(img_path)
            img = _resize_to_long_edge(img, 1440)
            out_path = _unique_output_path(uploads_dir, img_path.stem)
            img.save(out_path, "JPEG", quality=82, optimize=True)
            file_paths.append(str(out_path))
        except Exception as e:
            print(f"[ingest] Skipped {img_path.name}: {e}")
            continue

    return LocalIngestResponse(file_paths=file_paths, total_found=total_found)
