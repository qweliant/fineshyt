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
* ``POST /api/v1/convert`` — open a single source file (RAW or otherwise),
  compute technical quality scores (sharpness, exposure, overall) on the
  full-resolution image, resize to a 1440px long edge, save as quality-82
  JPEG into ``STATIC_UPLOADS_DIR``, and return the new path plus scores.

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
import pickle
import threading
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

import instructor
import numpy as np
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

# CLIP model — open_clip ViT-L-14 checkpoint. 768-dim image embeddings.
CLIP_MODEL_NAME = os.getenv("CLIP_MODEL_NAME", "ViT-L-14")
CLIP_PRETRAINED = os.getenv("CLIP_PRETRAINED", "laion2b_s32b_b82k")
CLIP_EMBED_DIM = 768
# cuda → mps → cpu by default; override with CLIP_DEVICE=cpu to force.
CLIP_DEVICE = os.getenv("CLIP_DEVICE", "auto")

# Preference model (scikit-learn Ridge linear probe) lives alongside other
# fineshyt state. Override with $FINESHYT_MODEL_DIR for tests.
FINESHYT_MODEL_DIR = Path(os.getenv("FINESHYT_MODEL_DIR", str(Path.home() / ".fineshyt")))
PREFERENCE_MODEL_PATH = FINESHYT_MODEL_DIR / "preference_model.pkl"

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


class ConvertRequest(BaseModel):
    file_path: str


class ConvertResponse(BaseModel):
    jpeg_path: str
    technical_score: int
    sharpness_score: int
    exposure_score: int



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


# Camera RAW formats — handled by rawpy if available. Non-RAW formats fall
# through to Pillow's native openers.
_RAW_EXTS = {".cr2", ".cr3", ".nef", ".arw", ".dng", ".raf", ".orf", ".rw2", ".pef", ".srw", ".x3f", ".3fr", ".erf", ".mef", ".mos", ".nrw", ".raw"}

try:
    import rawpy
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


# Scoring is done on a downsampled grayscale copy so the numbers are comparable
# across source resolutions (a 45MP RAW and a 12MP JPEG should land in the same
# range for the same scene). Still run on the pre-1440 image — the 1440 JPEG has
# already lost most of the high-frequency detail we're measuring.
_SCORE_LONG_EDGE = 1024


def _score_downsample(img: Image.Image) -> np.ndarray:
    """Convert to grayscale, downsample to ``_SCORE_LONG_EDGE``, return float32 array."""
    gray = img.convert("L")
    w, h = gray.size
    if max(w, h) > _SCORE_LONG_EDGE:
        if w >= h:
            gray = gray.resize((_SCORE_LONG_EDGE, round(h * _SCORE_LONG_EDGE / w)), Image.BILINEAR)
        else:
            gray = gray.resize((round(w * _SCORE_LONG_EDGE / h), _SCORE_LONG_EDGE), Image.BILINEAR)
    return np.asarray(gray, dtype=np.float32)


def _sharpness_score(gray: np.ndarray) -> int:
    """Variance-of-Laplacian sharpness, normalized to 0..100.

    Higher variance = more high-frequency content = sharper. The 300.0 divisor
    was picked so typical in-focus photos land in the 70-100 range; clearly
    blurry shots drop under 30. Revisit after seeing real numbers.
    """
    # 3x3 Laplacian via array slicing (avoids pulling in scipy)
    c = gray[1:-1, 1:-1]
    lap = 4.0 * c - gray[:-2, 1:-1] - gray[2:, 1:-1] - gray[1:-1, :-2] - gray[1:-1, 2:]
    var = float(lap.var())
    return int(round(min(var / 300.0, 1.0) * 100))


def _exposure_score(gray: np.ndarray) -> int:
    """Penalize histogram clipping at the black and white points.

    Counts pixels within 5 levels of either endpoint — JPEG quantization and
    scene noise mean truly crushed/blown regions cluster near 0/255 rather
    than landing on them exactly, so a strict `== 0 | == 255` test misses
    almost everything. Up to 0.5% combined clipped pixels is free (normal
    high-contrast scenes), and the score falls linearly to 0 at 5% clipped.
    """
    total = gray.size
    clipped = float(((gray <= 5.0) | (gray >= 250.0)).sum()) / total
    if clipped <= 0.005:
        return 100
    if clipped >= 0.05:
        return 0
    return int(round((1.0 - (clipped - 0.005) / 0.045) * 100))


def _compute_quality_scores(img: Image.Image) -> dict[str, int]:
    """Compute technical quality scores from a full-resolution PIL image.

    Returns sharpness, exposure, and a weighted overall score. The weights
    (0.7 sharpness, 0.3 exposure) reflect that blur is usually a harder cull
    than mild clipping; retune against real data.
    """
    gray = _score_downsample(img)
    sharpness = _sharpness_score(gray)
    exposure = _exposure_score(gray)
    overall = int(round(0.7 * sharpness + 0.3 * exposure))
    return {"sharpness": sharpness, "exposure": exposure, "overall": overall}


def _unique_output_path(uploads_dir: Path, stem: str) -> Path:
    """Return a non-colliding ``<stem>.jpg`` path inside ``uploads_dir``, suffixing ``_N`` on collision."""
    out = uploads_dir / f"{stem}.jpg"
    counter = 1
    while out.exists():
        out = uploads_dir / f"{stem}_{counter}.jpg"
        counter += 1
    return out


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
        # Score on the full-resolution image — the 1440 JPEG has already lost
        # the high-frequency detail that sharpness/clipping measurements rely on.
        scores = _compute_quality_scores(img)
        img = _resize_to_long_edge(img, 1440)
        uploads_dir = Path(STATIC_UPLOADS_DIR)
        uploads_dir.mkdir(parents=True, exist_ok=True)
        out = _unique_output_path(uploads_dir, path.stem)
        img.save(out, "JPEG", quality=82, optimize=True)
        return ConvertResponse(
            jpeg_path=str(out),
            technical_score=scores["overall"],
            sharpness_score=scores["sharpness"],
            exposure_score=scores["exposure"],
        )
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=_error_detail("convert", e, file_path=str(path)),
        )


# ─── CLIP embeddings + preference learning ──────────────────────────────────
#
# Two-stage personalization: CLIP image encoder produces a 768-dim image
# embedding; a scikit-learn Ridge regression head fits those embeddings
# against the user's 1–5 star ratings and predicts a preference score for
# unrated photos. The CLIP model is loaded lazily so test imports and cold
# starts don't pay the ~900MB download cost unless embeddings are actually
# requested. The preference model is pickled to disk (versioned by an
# integer) so scores can be compared across retrains.

_clip_state: dict[str, Any] = {"model": None, "preprocess": None, "device": None}
_clip_lock = threading.Lock()

_pref_state: dict[str, Any] = {"model": None, "scaler": None, "version": 0, "mtime": 0.0}
_pref_lock = threading.Lock()


def _resolve_clip_device() -> str:
    """Pick the CLIP inference device — honors ``$CLIP_DEVICE`` override."""
    if CLIP_DEVICE != "auto":
        return CLIP_DEVICE
    import torch

    if torch.cuda.is_available():
        return "cuda"
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def _get_clip():
    """Lazily load the CLIP model + preprocess transform, cached process-wide.

    Returns a tuple ``(model, preprocess, device)``. First call pays the
    download + load cost (~900MB for ViT-L-14 laion2b). Subsequent calls are
    a dict lookup. Thread-safe — the double-check lock pattern keeps concurrent
    embed requests from loading the model twice.
    """
    if _clip_state["model"] is not None:
        return _clip_state["model"], _clip_state["preprocess"], _clip_state["device"]

    with _clip_lock:
        if _clip_state["model"] is not None:
            return _clip_state["model"], _clip_state["preprocess"], _clip_state["device"]

        import open_clip
        import torch

        device = _resolve_clip_device()
        logger.info("Loading CLIP model=%s pretrained=%s device=%s", CLIP_MODEL_NAME, CLIP_PRETRAINED, device)
        model, _, preprocess = open_clip.create_model_and_transforms(
            CLIP_MODEL_NAME, pretrained=CLIP_PRETRAINED
        )
        model.eval()
        model.to(device)
        _clip_state["model"] = model
        _clip_state["preprocess"] = preprocess
        _clip_state["device"] = device
        _clip_state["torch"] = torch
        return model, preprocess, device


def _embed_image(path: Path) -> list[float]:
    """Open ``path`` and return its L2-normalized CLIP image embedding as a Python list."""
    model, preprocess, device = _get_clip()
    torch = _clip_state["torch"]

    img = _open_as_pil(path)
    tensor = preprocess(img).unsqueeze(0).to(device)
    with torch.no_grad():
        feats = model.encode_image(tensor)
        feats = feats / feats.norm(dim=-1, keepdim=True)
    return feats.squeeze(0).detach().cpu().float().tolist()


def _load_preference_model() -> dict[str, Any] | None:
    """Load the pickled preference model, reloading if the file's mtime changed.

    Returns a dict ``{"model", "scaler", "version"}`` or ``None`` if no model
    has been trained yet. Mtime tracking means the score endpoint picks up a
    fresh train without a restart.
    """
    if not PREFERENCE_MODEL_PATH.exists():
        return None

    mtime = PREFERENCE_MODEL_PATH.stat().st_mtime
    with _pref_lock:
        if _pref_state["model"] is not None and mtime == _pref_state["mtime"]:
            return _pref_state

        with open(PREFERENCE_MODEL_PATH, "rb") as f:
            payload = pickle.load(f)
        _pref_state["model"] = payload["model"]
        _pref_state["scaler"] = payload["scaler"]
        _pref_state["version"] = payload["version"]
        _pref_state["mtime"] = mtime
        logger.info("Loaded preference model version=%s", payload["version"])
        return _pref_state


class EmbedRequest(BaseModel):
    file_path: str


class EmbedResponse(BaseModel):
    embedding: list[float]
    model: str
    dim: int


class PreferenceSample(BaseModel):
    embedding: list[float]
    rating: int = Field(ge=1, le=5)


class PreferenceTrainRequest(BaseModel):
    samples: list[PreferenceSample]
    min_samples: int = 20


class PreferenceTrainResponse(BaseModel):
    model_version: int
    n_samples: int
    train_r2: float
    trained_at: str


class PreferenceScoreRequest(BaseModel):
    embeddings: list[list[float]]


class PreferenceScoreResponse(BaseModel):
    scores: list[int]
    model_version: int


@app.post("/api/v1/embed", response_model=EmbedResponse, tags=["Preference"])
def embed_file(request: EmbedRequest):
    """Compute the CLIP image embedding for a single file on disk.

    Loads the image via ``_open_as_pil`` (handles RAW + Pillow-native
    formats), runs it through the CLIP vision encoder, L2-normalizes the
    output, and returns a 768-dim float vector. Called once per photo by
    the Elixir ``EmbeddingWorker`` after curation succeeds.
    """
    path = Path(request.file_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail=f"File not found: {request.file_path}")

    try:
        embedding = _embed_image(path)
        return EmbedResponse(embedding=embedding, model=CLIP_MODEL_NAME, dim=CLIP_EMBED_DIM)
    except Exception as e:
        raise HTTPException(
            status_code=_status_for(e),
            detail=_error_detail("embed", e, file_path=str(path)),
        )


@app.post("/api/v1/preference/train", response_model=PreferenceTrainResponse, tags=["Preference"])
def train_preference_model(request: PreferenceTrainRequest):
    """Fit a Ridge regression linear probe on rated photos and persist it.

    Expects a list of ``{embedding, rating}`` samples gathered by the
    Elixir ``PreferenceTrainWorker`` via ``Photos.list_rated_with_embeddings/0``.
    Standardizes the embeddings, fits ``Ridge(alpha=1.0)`` on the rating
    labels, pickles ``{model, scaler, version}`` to ``PREFERENCE_MODEL_PATH``,
    and returns the new model version.

    If fewer than ``min_samples`` labeled examples are provided, returns
    400 so the worker can log-and-skip without incrementing the version.
    """
    if len(request.samples) < request.min_samples:
        raise HTTPException(
            status_code=400,
            detail=_error_detail(
                "preference_train",
                ValueError(f"need >= {request.min_samples} samples, got {len(request.samples)}"),
                n_samples=len(request.samples),
                min_samples=request.min_samples,
            ),
        )

    try:
        from sklearn.linear_model import Ridge
        from sklearn.preprocessing import StandardScaler

        X = np.asarray([s.embedding for s in request.samples], dtype=np.float32)
        y = np.asarray([s.rating for s in request.samples], dtype=np.float32)

        scaler = StandardScaler()
        X_scaled = scaler.fit_transform(X)

        model = Ridge(alpha=1.0)
        model.fit(X_scaled, y)
        train_r2 = float(model.score(X_scaled, y))

        # Bump version = previous + 1. Zero on fresh install.
        prev = _load_preference_model()
        new_version = (prev["version"] if prev else 0) + 1

        FINESHYT_MODEL_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "model": model,
            "scaler": scaler,
            "version": new_version,
            "clip_model": CLIP_MODEL_NAME,
            "embed_dim": CLIP_EMBED_DIM,
        }
        with open(PREFERENCE_MODEL_PATH, "wb") as f:
            pickle.dump(payload, f)

        # Refresh the in-memory cache so the next score call doesn't have to
        # re-read from disk.
        with _pref_lock:
            _pref_state["model"] = model
            _pref_state["scaler"] = scaler
            _pref_state["version"] = new_version
            _pref_state["mtime"] = PREFERENCE_MODEL_PATH.stat().st_mtime

        trained_at = datetime.now(timezone.utc).isoformat()
        logger.info(
            "Trained preference model version=%s n_samples=%d train_r2=%.4f",
            new_version, len(request.samples), train_r2,
        )
        return PreferenceTrainResponse(
            model_version=new_version,
            n_samples=len(request.samples),
            train_r2=train_r2,
            trained_at=trained_at,
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=_error_detail("preference_train", e, n_samples=len(request.samples)),
        )


@app.post("/api/v1/preference/score", response_model=PreferenceScoreResponse, tags=["Preference"])
def score_preference(request: PreferenceScoreRequest):
    """Score a batch of pre-computed embeddings against the fitted preference model.

    Ridge predicts a float in the 1–5 rating space; we linearly map that to
    a 0–100 integer (rating 1 → 0, rating 5 → 100, clamped). If no preference
    model has been trained yet, returns 400 so the caller can gracefully skip.
    """
    state = _load_preference_model()
    if state is None:
        raise HTTPException(
            status_code=400,
            detail=_error_detail(
                "preference_score",
                RuntimeError("no preference model trained yet"),
                n_embeddings=len(request.embeddings),
            ),
        )

    try:
        X = np.asarray(request.embeddings, dtype=np.float32)
        X_scaled = state["scaler"].transform(X)
        preds = state["model"].predict(X_scaled)
        # Map rating [1,5] → score [0,100]. interp handles out-of-range gracefully.
        scores = np.clip(np.round((preds - 1.0) * 25.0), 0, 100).astype(int).tolist()
        return PreferenceScoreResponse(scores=scores, model_version=state["version"])
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=_error_detail("preference_score", e, n_embeddings=len(request.embeddings)),
        )
