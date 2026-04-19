"""Lazy-loaded CLIP ViT-L-14 encoder, with a thin `embed_image` wrapper.

First call pays the ~900MB download + load cost; subsequent calls are a
dict lookup. Thread-safe via double-checked locking so concurrent embed
requests don't load the model twice.
"""

import threading
from pathlib import Path
from typing import Any

from fineshyt_ai.config import CLIP_DEVICE, CLIP_MODEL_NAME, CLIP_PRETRAINED, logger
from fineshyt_ai.imaging.io import open_as_pil

_state: dict[str, Any] = {"model": None, "preprocess": None, "device": None}
_lock = threading.Lock()


def _resolve_device() -> str:
    """Pick the CLIP inference device — honors $CLIP_DEVICE override."""
    if CLIP_DEVICE != "auto":
        return CLIP_DEVICE
    import torch

    if torch.cuda.is_available():
        return "cuda"
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def get_clip():
    """Return `(model, preprocess, device)`, loading on first call."""
    if _state["model"] is not None:
        return _state["model"], _state["preprocess"], _state["device"]

    with _lock:
        if _state["model"] is not None:
            return _state["model"], _state["preprocess"], _state["device"]

        import open_clip
        import torch

        device = _resolve_device()
        logger.info(
            "Loading CLIP model=%s pretrained=%s device=%s",
            CLIP_MODEL_NAME, CLIP_PRETRAINED, device,
        )
        model, _, preprocess = open_clip.create_model_and_transforms(
            CLIP_MODEL_NAME, pretrained=CLIP_PRETRAINED
        )
        model.eval()
        model.to(device)
        _state["model"] = model
        _state["preprocess"] = preprocess
        _state["device"] = device
        _state["torch"] = torch
        return model, preprocess, device


def embed_image(path: Path) -> list[float]:
    """Return the L2-normalized CLIP image embedding for the file at `path`."""
    model, preprocess, device = get_clip()
    torch = _state["torch"]

    img = open_as_pil(path)
    tensor = preprocess(img).unsqueeze(0).to(device)
    with torch.no_grad():
        feats = model.encode_image(tensor)
        feats = feats / feats.norm(dim=-1, keepdim=True)
    return feats.squeeze(0).detach().cpu().float().tolist()
