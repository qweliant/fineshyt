"""Runtime configuration loaded from environment variables.

All `os.getenv` calls for the service live here. Imported at module load
time so a missing/invalid var fails fast rather than surfacing deep in a
request handler. Kept as module-level constants — `pydantic-settings` is
a reasonable upgrade once the set grows, but this is fine for now.
"""

import logging
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("fineshyt.ai_worker")

# ── LLM ───────────────────────────────────────────────────────────────────
LLM_BASE_URL = os.getenv("LLM_BASE_URL", "http://localhost:11434/v1/")
LLM_API_KEY = os.getenv("LLM_API_KEY", "ollama")
LLM_MODEL = os.getenv("LLM_MODEL", "llava")

# ── Converted-JPEG output ─────────────────────────────────────────────────
# Must match the orchestrator's priv/static/uploads/ so the LiveView can
# serve the converted JPEGs.
STATIC_UPLOADS_DIR = Path(os.getenv("STATIC_UPLOADS_DIR", "/tmp/fineshyt_uploads"))

# ── CLIP ──────────────────────────────────────────────────────────────────
CLIP_MODEL_NAME = os.getenv("CLIP_MODEL_NAME", "ViT-L-14")
CLIP_PRETRAINED = os.getenv("CLIP_PRETRAINED", "laion2b_s32b_b82k")
CLIP_EMBED_DIM = 768
# cuda → mps → cpu by default; override with CLIP_DEVICE=cpu to force.
CLIP_DEVICE = os.getenv("CLIP_DEVICE", "auto")

# ── Preference model (pickled Ridge + scaler) ─────────────────────────────
FINESHYT_MODEL_DIR = Path(os.getenv("FINESHYT_MODEL_DIR", str(Path.home() / ".fineshyt")))
PREFERENCE_MODEL_PATH = FINESHYT_MODEL_DIR / "preference_model.pkl"
