# ai_worker

The Python / FastAPI inference microservice for [Fine.Shyt](../README.md). The Elixir [orchestrator](../orchestrator/) coordinates the pipeline and calls this service over HTTP for the ML-heavy steps.

It's **stateless and filesystem-independent** — `/convert`, `/curate`, and `/embed` all receive image **bytes** as multipart uploads (the orchestrator reads the originals off disk and streams them), so this service needs no access to the user's photo library. That's what lets it run in a container even when photos live on a drive Docker can't mount.

## Endpoints

| Endpoint | Does | Backed by |
| --- | --- | --- |
| `POST /api/v1/convert` | source image bytes → resized 1440px JPEG + sharpness/exposure + EXIF | Pillow + rawpy (libraw) |
| `POST /api/v1/curate` | image bytes → structured `PhotoMetadata` (subject, mood, tags…) | vision LLM via `instructor` |
| `POST /api/v1/embed` | image bytes → 768-dim L2-normalized CLIP vector | open_clip ViT-L-14 |
| `POST /api/v1/preference/{train,score}` | `{embedding, rating}` samples → Ridge model / scores | scikit-learn |
| `POST /api/v1/detect_bursts` | `{id, embedding, captured_at}[]` → near-duplicate groups | cosine sim + timestamps |
| `POST /api/v1/exif`, `/quality_scores` | path-based backfill ops | — |

Code is split along a transport/domain seam: each ML op is a plain function in `src/fineshyt_ai/domain/`, and `src/fineshyt_ai/transports/http/` is the thin FastAPI layer.

## Config (env vars, see `src/fineshyt_ai/config.py`)

- `LLM_BASE_URL` / `LLM_API_KEY` / `LLM_MODEL` — the vision LLM. Desktop spawns a local `llama-server` (Qwen2.5-Omni); from a container reach the host at `http://host.docker.internal:11434/v1/`. Any OpenAI-compatible endpoint works (Ollama, Claude, HuggingFace).
- `STATIC_UPLOADS_DIR` — where converted JPEGs are written (shared with the orchestrator).
- `CLIP_MODEL_NAME` / `CLIP_PRETRAINED` / `CLIP_DEVICE` — defaults `ViT-L-14` / `laion2b_s32b_b82k` / auto (cuda→mps→cpu).

## Dev

```bash
uv sync
uv run fastapi dev src/main.py --reload   # http://localhost:8000/docs
```

From the repo root, `make dev` runs this alongside the orchestrator.

## Footprint note (C4)

The installed deps are ~4.6 GB, but ~2.8 GB of that is **unused CUDA libraries** — the default torch wheel is the `+cu130` build, while CLIP runs on CPU/Metal here. The planned C4 work (freezing this service into a native binary to drop Docker entirely) starts with switching to **CPU-only torch**, which cuts site-packages to ~1.2 GB. See [../desktop/README.md](../desktop/README.md) for the roadmap.
