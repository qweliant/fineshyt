# FINE. SHYT.

I take photos. Mostly macro, mostly botanical, mostly black and white, mostly things other people walk past without a second look. After a while you accumulate a lot of TIFFs and an existential question: which of these are actually good and which am I just emotionally attached to because I spent 45 minutes on my knees in the dirt to get the shot.

This project is my answer to that question. I described my own aesthetic to an AI and let it go through my archive and tell me what fits. Fine shyt, if you will.

It's also an excuse to get back into ML. The last time I did anything in this space was [deploying a transformer model in 2021](https://qwelian.com/posts/Deploying_Transformer_Models). Which like in AI years, is basically the Jurassic period. A lot has changed. Vision models that can actually reason about composition and aesthetic? That's new and worth playing with.

## What it does

You give it a style description in plain english. Something like "high grain, soft focus, B&W, mood: solitary." You point it at a directory on your hard drive — I've got about a TB of TIFFs on an external drive that had never been properly sorted — and it randomly samples N files, converts whatever it finds down to workable JPEGs, runs each one through a vision LLM, and the LLM decides: does this fit the vibe or not.

Results go into a gallery. You can filter by match, no match, or everything. Each photo gets a score and a one-sentence explanation. The whole thing updates in real-time while the jobs run. No refreshing, no polling, just Phoenix doing what Phoenix does.

After you've rated enough photos you start to see clusters. You assign project names manually in the gallery. Then you export the approved ones to your blog.

Single image curation still works too, at `/`. Drop a photo, get a museum placard back.

## Architecture

Two services, intentionally decoupled.

**The Orchestrator** (`/orchestrator`) — Elixir, Phoenix LiveView, Oban, PostgreSQL. This is the main service. It owns the UI, the job queue, the database, and the pub/sub fanout that makes the real-time updates work. Oban handles retries with backoff so a slow inference call doesn't just silently disappear.

**The AI Worker** (`/ai_worker`) — Python, FastAPI, Instructor. This is the muscle. Stateless. It gets an image over HTTP, encodes it to base64, asks the vision model what it sees, and enforces the response into a strict Pydantic schema via `instructor`. It also handles local image ingestion — walking directories, converting RAW/TIFF/JPEG to normalized JPEGs for the queue.

The two services talk over plain HTTP. You could swap out either side without touching the other. Python has the AI ecosystem, Elixir has the concurrency story. No reason to compromise on either.

## LLM options

The worker is configured via environment variables so you can point it at whatever you have:

```bash
# Local (default) — needs Ollama running with llava pulled
LLM_BASE_URL=http://localhost:11434/v1/
LLM_API_KEY=ollama
LLM_MODEL=llava

# Claude
LLM_BASE_URL=https://api.anthropic.com/v1/
LLM_API_KEY=sk-ant-...
LLM_MODEL=claude-opus-4-6

# HuggingFace
LLM_BASE_URL=https://api-inference.huggingface.co/v1/
LLM_API_KEY=hf_...
LLM_MODEL=meta-llama/Llama-3.2-11B-Vision-Instruct
```

Local inference is free and private but will make your fans spin. Claude is genuinely good at this. It reasons about aesthetic intent, not just subject matter, which is exactly what you need when the question is "does this fit a style" rather than "what is in this image."

## Ingesting photos

Point it at a directory. It walks recursively and picks up TIFF, JPEG, PNG, WebP, and camera RAW files (CR2, CR3, NEF, ARW, DNG, etc. — needs `libraw` installed for RAW support). Set how many to sample and hit import in the gallery.

```bash
# macOS libraw for RAW file support
brew install libraw
```

Set `STATIC_UPLOADS_DIR` in `ai_worker/.env` to point at the orchestrator's static uploads folder:

```bash
STATIC_UPLOADS_DIR=/path/to/fineshyt/orchestrator/priv/static/uploads
```

Phase 1 is sampling a few hundred at random, rating them, seeing what the LLM is doing. Phase 2 is larger batches once you trust the scores.

## Blog export

When you've rated enough and the projects have names, export the approved photos:

```bash
cd orchestrator && mix fineshyt.export --target /path/to/blog/photos
```

Approved means rated 4+ stars or scored 75+. Unrated photos never export — the whole point is that you had an opinion about it first. Export is additive, existing files don't get touched, and a `photos.json` manifest gets written alongside the images with filename, tags, mood, style score, and project name. Your blog reads from that.

## Running it

Prerequisites: [Mise](https://mise.jdx.dev/), [uv](https://github.com/astral-sh/uv), [Docker](https://www.docker.com/).

First time:

```bash
make setup
```

Every time after that:

```bash
make dev
```

- Gallery + single upload: [localhost:4000](http://localhost:4000)
- AI worker API docs: [localhost:8000/docs](http://localhost:8000/docs)

## Future work

Features that would complement what's already here. Each needs research before implementation.

**CLIP embeddings + pgvector search** — The current gallery search is substring matching on subject and mood. CLIP embeddings would unlock natural language retrieval: "find moody portraits with side lighting," "photos like this one but sharper," "find the selects I'd probably post." pgvector plugs into the existing Postgres instance — no new infrastructure. CLIP inference runs in the ai_worker alongside the existing vision LLM calls.

**Technical quality scoring** — `style_score` measures aesthetic fit against your description. It says nothing about whether the photo is technically sound. Heuristic scoring for sharpness, exposure, noise, and motion blur using Pillow and numpy (both already in the worker's deps) would give a separate axis for culling. A sharp but off-brand photo and a perfectly-on-brand but blurry photo shouldn't score the same.

**Perceptual duplicate detection** — Deduplication today is filename-stem based: if `DSC_0042.tiff` and `DSC_0042.jpg` both exist, only one gets ingested. That misses actual visual duplicates across different filenames — re-exports, crops, edits. Perceptual hashing or embedding cosine distance would catch those.

**Preference learning / feedback loop** — User ratings (1–5 stars) exist but are write-only. They don't feed back into how future photos get scored. A reranker trained on your rating history would let `style_score` drift toward your actual taste over time instead of relying solely on the text description. This is the "gets smarter as you use it" piece.

**Burst / sequence best-pick** — Use EXIF timestamps and visual similarity to detect burst sequences, then auto-pick the sharpest frame. Lower priority if you mostly shoot deliberate single frames, high priority for event or action shoots.


## Author

Qwelian Tanner — [qwelian.com](https://www.qwelian.com)
