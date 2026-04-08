"""Fineshyt AI worker — FastAPI service for photo curation and conversion.

This service is the Python half of the fineshyt photo pipeline. It runs
locally (default port 8000) and is called by the Elixir orchestrator's
Oban workers (`Orchestrator.Workers.AiCurationWorker` and
`Orchestrator.Workers.ConversionWorker`).

Endpoints
---------
* ``POST /api/v1/curate`` — accept an image upload and an optional style
  description, ask LLaVA (via Ollama via the `instructor` structured-output
  wrapper) to extract metadata, and return it as a `PhotoMetadata` JSON.
* ``POST /api/v1/ingest/local`` — walk a directory, return every supported
  image path (optionally random-sampled). No file mutation.
* ``POST /api/v1/convert`` — open a single source file (RAW or otherwise),
  resize to a 1440px long edge, save as quality-82 JPEG into
  ``STATIC_UPLOADS_DIR``, and return the new path.

Structured error contract
-------------------------
Every endpoint funnels failures through ``_error_detail`` so that
``HTTPException.detail`` is always a JSON object with the shape::

    {
      "op": "curate" | "convert",
      "error_type": "<Python exception class name>",
      "message": "<str(exc)>",
      "context": {...},
      "upstream": {"status_code": int, "code": str, "message": str, "body": ...}
    }

The Elixir worker parses this in ``format_api_error/1`` so the user sees
a real reason in the gallery and the ``/logs`` page instead of a bare
500. ``_status_for`` similarly maps ``openai.APIError`` upstream codes
through (404 model not found, 413 payload too large, 429 rate limited,
503 unavailable, etc. — see https://docs.ollama.com/api/errors).

Configuration
-------------
Read from environment via ``python-dotenv``:

* ``LLM_BASE_URL`` — default ``http://localhost:11434/v1/`` (Ollama)
* ``LLM_API_KEY`` — default ``"ollama"`` (Ollama ignores it but openai
  client requires a non-empty value)
* ``LLM_MODEL`` — default ``"llava"``
* ``STATIC_UPLOADS_DIR`` — must match the orchestrator's
  ``priv/static/uploads/`` so the LiveView can serve the converted JPEGs
"""

import base64
import logging
import os
import random
import traceback
from pathlib import Path
from typing import Any, Literal

import instructor
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from openai import APIError, AsyncOpenAI
from PIL import Image
from pydantic import BaseModel, Field

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("fineshyt.ai_worker")

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
    subject: str = Field(description="The primary subject of the photo. Be specific — describe what is actually depicted.")
    content_type: Literal["portrait", "street", "family", "landscape", "still_life", "architecture", "abstract", "other"] = Field(
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
    suggested_tags: list[str] = Field(description="5 to 7 specific tags describing technique, mood, or subject for a portfolio database. Do not include generic terms like 'photography' or 'photo'.")
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


class ConvertRequest(BaseModel):
    file_path: str


class ConvertResponse(BaseModel):
    jpeg_path: str



@app.post("/api/v1/curate", response_model=PhotoMetadata, tags=["Agent Workflow"])
async def curate_photo(
    file: UploadFile = File(...),
    style_description: str = Form(""),
):
    """Curate a single photo via LLaVA and return structured metadata.

    Encodes the upload as base64, builds a multimodal prompt (with an
    optional style-match instruction when ``style_description`` is given),
    and asks the LLM to fill out a ``PhotoMetadata`` schema via
    ``instructor``. ``instructor`` retries up to 3 times to coerce a valid
    response, but does not protect against upstream connection errors.

    Args:
        file: Multipart upload. ``file.content_type`` must start with
            ``image/`` or the request is rejected with HTTP 400.
        style_description: Optional photographer style. When non-empty,
            the LLM is asked to set ``style_match``, ``style_score``, and
            ``style_reason`` against this description; when empty, those
            three fields are explicitly set to false / 0 / "".

    Returns:
        PhotoMetadata: subject, content_type, lighting_critique,
        artistic_mood, suggested_tags, style_match, style_score,
        style_reason.

    Raises:
        HTTPException: 400 if the upload is not an image. Otherwise the
        upstream status from ``_status_for`` (often 404, 429, 500, 503),
        with ``detail`` set to the structured payload from
        ``_error_detail``.

    Example:
        ``curl -F file=@photo.jpg -F style_description='moody, cinematic' \\
            http://127.0.0.1:8000/api/v1/curate``
    """
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
                            "text": (
                                "You are an expert photo curator. Analyze this photograph and extract the metadata. "
                                "Be accurate about content_type — most photos are of people (portrait, family, street). "
                                "Only use 'still_life' for photos where objects are the clear, intentional subject with no people present. "
                                "Only use 'abstract' for photos that are genuinely non-representational.\n\n"
                                f"{style_prompt}"
                            ),
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
        raise HTTPException(
            status_code=_status_for(e),
            detail=_error_detail("curate", e, filename=file.filename),
        )


def _status_for(exc: Exception) -> int:
    """Map an exception to a meaningful HTTP status code.

    Unwraps ``openai.APIError`` (and subclasses) so that an upstream
    Ollama error code reaches the Elixir caller intact instead of being
    collapsed to a generic 500. Ollama follows standard HTTP semantics
    (see https://docs.ollama.com/api/errors): 400 invalid request, 404
    model not found, 413 payload too large, 429 rate limited, 499 client
    closed, 500 server error, 503 unavailable.

    Args:
        exc: Any exception. Non-APIError instances always return 500.

    Returns:
        int: An HTTP status code in the 400–599 range.

    Example:
        >>> from openai import APIError
        >>> _status_for(ValueError("oops"))
        500
    """
    if isinstance(exc, APIError):
        status = getattr(exc, "status_code", None)
        if isinstance(status, int) and 400 <= status < 600:
            return status
    return 500


def _error_detail(op: str, exc: Exception, **context: Any) -> dict[str, Any]:
    """Build a structured error payload and log the full traceback.

    The returned dict is what FastAPI ultimately serializes as JSON
    ``detail`` on an ``HTTPException``. The Elixir side parses this in
    ``Orchestrator.Workers.AiCurationWorker.format_api_error/1`` so the
    user sees a real reason in the gallery and the ``/logs`` page instead
    of a bare HTTP status. As a side effect, the full traceback plus the
    structured fields are logged via the stdlib logger.

    Args:
        op: Short operation identifier, e.g. ``"curate"`` or
            ``"convert"``. Surfaces in logs and the response body so the
            Elixir side can route the failure to the right error category.
        exc: The exception that triggered the failure. Subclasses of
            ``openai.APIError`` are unwrapped to expose ``status_code``,
            ``code``, ``message``, and ``body`` under ``upstream``.
        **context: Arbitrary additional fields to attach (e.g.
            ``filename=file.filename``, ``file_path=str(path)``).

    Returns:
        dict: Always contains ``op``, ``error_type``, ``message``, and
        ``context``. When ``exc`` is an ``APIError``, also includes
        ``upstream`` with the unwrapped fields.

    Example:
        >>> _error_detail("curate", ValueError("bad"), filename="a.jpg")
        {'op': 'curate', 'error_type': 'ValueError', 'message': 'bad', 'context': {'filename': 'a.jpg'}}
    """
    exc_type = type(exc).__name__
    message = str(exc) or exc_type

    upstream: dict[str, Any] = {}
    if isinstance(exc, APIError):
        # openai.APIError has .status_code, .code, .message, .body, .request
        upstream["status_code"] = getattr(exc, "status_code", None)
        upstream["code"] = getattr(exc, "code", None)
        upstream["message"] = getattr(exc, "message", None)
        body = getattr(exc, "body", None)
        if body is not None:
            upstream["body"] = body

    payload: dict[str, Any] = {
        "op": op,
        "error_type": exc_type,
        "message": message,
        "context": context,
    }
    if upstream:
        payload["upstream"] = upstream

    logger.error(
        "operation=%s failed: %s: %s | context=%s | upstream=%s\n%s",
        op,
        exc_type,
        message,
        context,
        upstream or None,
        traceback.format_exc(),
    )
    return payload


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
    """Open any supported image (RAW or PIL-native) and return an RGB ``PIL.Image``."""
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
    """Resize ``img`` so its longer edge equals ``long_edge``, preserving aspect ratio."""
    w, h = img.size
    if max(w, h) <= long_edge:
        return img
    if w >= h:
        return img.resize((long_edge, round(h * long_edge / w)), Image.LANCZOS)
    return img.resize((round(w * long_edge / h), long_edge), Image.LANCZOS)


def _unique_output_path(uploads_dir: Path, stem: str) -> Path:
    """Return a non-colliding ``<stem>.jpg`` path inside ``uploads_dir``, suffixing ``_N`` on collision."""
    out = uploads_dir / f"{stem}.jpg"
    counter = 1
    while out.exists():
        out = uploads_dir / f"{stem}_{counter}.jpg"
        counter += 1
    return out


@app.post("/api/v1/ingest/local", response_model=LocalIngestResponse, tags=["Ingestion"])
def ingest_local(request: LocalIngestRequest):
    """Walk a local directory and return paths to every supported image file.

    Recursively scans ``request.dir_path``, filters out hidden files
    (including macOS ``._`` resource forks) and unsupported extensions,
    and optionally takes a random sample. Pure read — no conversion or
    DB writes happen here. The orchestrator's batch ingest path uses this
    to discover which files to enqueue for ``ConversionWorker``.

    Args:
        request: ``LocalIngestRequest`` with:
            * ``dir_path``: absolute directory to scan.
            * ``sample``: optional positive int. When set and smaller than
              the total found, randomly samples this many paths.

    Returns:
        LocalIngestResponse: ``file_paths`` (the chosen subset) and
        ``total_found`` (the unfiltered count, for the UI to show how
        many were sampled out of how many).

    Raises:
        HTTPException: 400 if ``dir_path`` is not a directory; 404 if no
        supported image files are found under it.
    """
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

    return LocalIngestResponse(
        file_paths=[str(p) for p in image_files],
        total_found=total_found,
    )


@app.post("/api/v1/convert", response_model=ConvertResponse, tags=["Ingestion"])
def convert_file(request: ConvertRequest):
    """Convert a single source file to a resized JPEG and write it to disk.

    Opens ``request.file_path`` (RAW via rawpy or JPEG/TIFF/PNG/etc. via
    Pillow), resizes so the long edge is 1440px, encodes as quality-82
    JPEG, and saves into ``STATIC_UPLOADS_DIR`` under a non-colliding
    ``<stem>.jpg`` filename. Called once per source file by the Elixir
    ``ConversionWorker``.

    Args:
        request: ``ConvertRequest`` with:
            * ``file_path``: absolute path to the source image.

    Returns:
        ConvertResponse: ``jpeg_path`` — absolute path to the new JPEG.

    Raises:
        HTTPException: 404 if ``file_path`` does not exist as a file;
        500 with structured ``_error_detail`` payload on any conversion
        failure (rawpy errors, Pillow errors, disk errors, etc.).
    """
    path = Path(request.file_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"File not found: {request.file_path}")

    try:
        img = _open_as_pil(path)
        img = _resize_to_long_edge(img, 1440)
        uploads_dir = Path(STATIC_UPLOADS_DIR)
        uploads_dir.mkdir(parents=True, exist_ok=True)
        out = _unique_output_path(uploads_dir, path.stem)
        img.save(out, "JPEG", quality=82, optimize=True)
        return ConvertResponse(jpeg_path=str(out))
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=_error_detail("convert", e, file_path=str(path)),
        )
