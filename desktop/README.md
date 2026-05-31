# Fine.Shyt Desktop Shell (experimental)

> Living on branch `experimental-tauri-native`. Phases C2, C5, and C3 are done; **C4 (freeze the Python ai_worker) is the last phase**. See the native-packaging plan doc for the full roadmap.

A Tauri 2.x shell that wraps Fine.Shyt's existing Phoenix LiveView UI in a native window. The shell is responsible for **lifecycle**: spawning the containerised Python ai_worker, spawning a **native Elixir release** for the orchestrator (with a native SQLite database — no Postgres since C3), spawning a native `llama-server` for the vision LLM, polling Phoenix, and tearing it all down on quit. The UI itself is unchanged.

## Why this exists

Photographers shouldn't have to open PowerShell, run `git clone`, paste `make compose`, and remember to `docker compose down` later. They should double-click an app. This is the smallest viable shell that delivers that experience without rewriting any backend code.

## Phase status

| Phase | Status | What runs natively | What's still Docker / extra prereq |
| --- | --- | --- | --- |
| C1 | done (superseded) | nothing | db, orchestrator, ai_worker, Ollama |
| C2 | done | orchestrator (Elixir release) | db, ai_worker, Ollama |
| C5 | done | + llama-server (vision LLM, via brew) | db, ai_worker |
| C3 | done | + SQLite database (Postgres removed) | ai_worker |
| **C4** | **in progress — Nuitka spike done** | **+ ai_worker (frozen via Nuitka)** | **— (zero host prereqs)** |

Phases shipped out of original order: C5 (Ollama removal) and C3 (Postgres → SQLite) were prioritised because Ollama (~5 GB download + separate install) and the DB container were the most-felt prereqs, and both had well-paved paths. C4 is last — freezing torch/CLIP is the hardest and biggest-binary phase. See the plan doc for the reasoning.

**C4 progress:**

1. **CPU-only torch** (`ai_worker/pyproject.toml` — pinned to `pytorch-cpu` index): cut site-packages **4.6 GB → 971 MB** by dropping `nvidia-*` + `triton`. Embedding parity vs the prior CUDA build: max abs diff `5.96e-08` (float32 noise). Prerequisite for freezing (CUDA's dynamic loading is what trips up the freezers).
2. **Packaging spikes — Nuitka and PyApp** (both target `fineshyt_ai.serve:main`, a `uvicorn.run(app)` entry; `fastapi run` is a CLI wrapper that isn't freezable):

   | Metric | Nuitka `--standalone` | PyApp launcher |
   | --- | --- | --- |
   | Build time (M3, cold) | ~90 min (7,973 modules → C → clang) | **~45 sec** (just compiles the Rust launcher) |
   | Distributable artifact | 1.5 GB (binary + bundled libs/data) | **3 MB launcher** (embeds the 27 KB wheel) |
   | First launch (truly cold, fresh user) | ~3 s after install | ~2–5 min (downloads Python + pip-installs deps) |
   | First launch (deps cached) | ~3 s | ~10 s (uv reuses cache) |
   | Warm `/embed` latency | 400–700 ms | ~400 ms |
   | Runtime RSS (CLIP loaded) | ~1 GB | ~0.94 GB |
   | `/embed` parity vs container | `4.25e-07` (float32 noise) | `2.66e-07` (float32 noise) |
   | `/convert` smoke test | works | works |
   | Iteration loop (code change → test) | re-freeze ≈ 90 min | rebuild wheel + launcher ≈ 30 s |
   | CI matrix cost (3 OSes per release) | ~hours of runner time | ~minutes |
   | Distribution model | Self-contained, offline-capable | Needs network on first launch (deps fetched from PyPI) |

   **Recommendation: PyApp.** Build-time, artifact-size, and dev-iteration wins are decisive. The only Nuitka advantage — offline first-launch — doesn't help our shape: first-launch needs network anyway for the CLIP weights (1.7 GB) and the Qwen GGUF (4.4 GB), both downloaded from HuggingFace on first run. PyApp adds ~1 GB of pip-installed deps to that same first-launch download, which is acceptable for a one-time setup (this is the Ollama / `pip install` UX that ML users expect).

   The Nuitka build is still functional in `ai_worker/build_nuitka/serve.dist/` if we want to revisit; PyApp is the production direction.

   PyApp setup (in `ai_worker/`):
   - `pyproject.toml` exposes `fineshyt-ai-worker` as a `[project.scripts]` entry → `fineshyt_ai.serve:main`.
   - `[build-system]` uses hatchling; sdist excludes `build_nuitka/` and `.venv/`.
   - Build wheel: `uv build` → `dist/ai_worker-0.1.0-py3-none-any.whl` (27 KB).
   - Launcher: `cargo install pyapp --force --root <dir>` with env `PYAPP_PROJECT_PATH=…/ai_worker-0.1.0-py3-none-any.whl PYAPP_PROJECT_NAME=ai_worker PYAPP_PROJECT_VERSION=0.1.0 PYAPP_EXEC_SPEC=fineshyt_ai.serve:main PYAPP_UV_ENABLED=1`.

**Tauri shell wired up:** `desktop/src-tauri/src/main.rs` spawns the PyApp launcher as a tracked child instead of running `docker compose up ai_worker`. The boot sequence is now all-native (orchestrator release + llama-server + PyApp launcher), shutdown SIGKILLs each child, and Docker is no longer touched at startup. **`make desktop-dev` now depends on `make ai-worker-launcher`**, which:

1. `uv build --wheel` → `ai_worker/dist/ai_worker-*.whl`
2. `cargo install pyapp` with `PYAPP_PROJECT_PATH` set to that wheel, `PYAPP_EXEC_SPEC=fineshyt_ai.serve:main`, `PYAPP_UV_ENABLED=1`, **`PYAPP_DISTRIBUTION_EMBED=1`** (so the launcher embeds python-build-standalone — no separate Python download at first launch)
3. Moves the resulting binary to `desktop/runtime/bin/fineshyt-ai-worker`

Launcher size with embedded Python: **~19 MB** (vs ~3 MB without embed). The +16 MB is python-build-standalone baked in — worth it for offline-capable first launch.

**Gotchas still open:**

- **Windows console flash.** PyApp's `cargo install pyapp` builds against the `console` subsystem by default, so on Windows the user sees a terminal flicker each time the Tauri shell spawns the launcher. The fix is a Cargo feature flag (or env var if PyApp surfaces one in the version we land on) that switches PyApp to `windows_subsystem = "windows"`. Can't be tested on macOS — wait until a Windows CI runner is up, then patch the `make ai-worker-launcher` target.
- **First-launch deps download (~1 GB) is not bundle-able.** The wheel is 27 KB; torch + CLIP + scipy + sklearn + open_clip = ~1 GB from PyPI on first launch. With embedded Python the user only waits for that and the CLIP weights (1.7 GB) + Qwen GGUF (4.4 GB) on first run — no Python install on top. Total cold-fresh first launch: ~10–20 min depending on network. Subsequent launches are seconds.
- **Linux torch-CPU pin.** On Linux, PyPI's default torch is the CUDA build (~3 GB extra). On Mac/Windows the default is already CPU. When the CI matrix adds Linux, the `ai-worker-launcher` target needs to pass an extra index (`PYAPP_PIP_EXTRA_ARGS=--extra-index-url …/whl/cpu`) or a constraints file specifically on Linux.

**Still ahead:**

- **CI matrix** (GH Actions: macOS + Windows + Linux runners) to build per-OS launchers + Tauri bundles on tag. Each platform-specific launcher is ~20 MB; the per-OS Tauri bundle wraps it.
- **First-launch progress UI** in the splash — the Rust shell knows when each port is "still waiting"; surface that as "Installing AI worker (~1 GB, one-time)…" / "Downloading vision model (~5 GB, one-time)…" instead of a generic spinner.

## What it does NOT do (yet)

- Bundle the Python ai_worker — it's still containerised (C4 will freeze it). Docker is still a host prereq for that one service. (Postgres is gone — the orchestrator uses native SQLite since C3.)
- Handle first-run config (PHOTO_LIBRARY, SECRET_KEY_BASE) interactively — edit `.env` per the root README. First-run wizard is a later phase.
- Code-sign or auto-update — dev builds only.

## Prerequisites

- Rust toolchain (`rustup`, `cargo`) — `cargo --version` should work.
- Node.js — only needed if you want to use `cargo tauri` CLI for packaged builds. Dev mode (`cargo run`) doesn't require it.
- Docker Desktop on the host (for the still-containerised ai_worker — the only remaining container since C3 dropped Postgres).
- `brew install llama.cpp` — provides the `llama-server` binary the shell spawns for the embedded vision LLM. (Replaces Ollama.)
- A built Phoenix release at `orchestrator/_build/prod/rel/orchestrator/bin/server`. Build it with `make release` from the repo root.
- The repo's normal `.env` set up (run `make compose-init` once at the repo root).

The vision GGUF (~5–7 GB) downloads automatically into `desktop/runtime/models/` on the first launch via llama-server's `-hf` flag.

## Run in dev mode

From the repo root, two commands the first time:

```bash
make release        # build the Elixir release (one-time, ~1 min)
make desktop-dev    # compile + launch the Tauri shell
```

Subsequent launches: just `make desktop-dev`. If you've changed Elixir code, re-run `make release` first to rebuild.

The boot flow you'll see in the terminal:

```text
[fineshyt-desktop] startup: resolving repo root
[fineshyt-desktop] startup: running `make compose-init` in ...
[fineshyt-desktop] startup: starting ai_worker via `--profile c2`
[fineshyt-desktop] startup: spawning llama-server (vision LLM)
[fineshyt-desktop] startup: waiting for llama-server on 127.0.0.1:11434 (first launch downloads ~5–7 GB)
... llama-server boot lines, including "server is listening on http://127.0.0.1:11434" ...
[fineshyt-desktop] startup: locating release binary
[fineshyt-desktop] startup: reading SECRET_KEY_BASE from .env
[fineshyt-desktop] startup: running orchestrator migrations
[fineshyt-desktop] startup: spawning native orchestrator release
... Phoenix log lines, including "Running OrchestratorWeb.Endpoint" ...
[fineshyt-desktop] startup: waiting for Phoenix on 127.0.0.1:4000
[fineshyt-desktop] startup: Phoenix is up; splash will detect and navigate.
```

**First-launch note:** the vision model GGUF (~5–7 GB) downloads from HuggingFace into `desktop/runtime/models/` on the very first run. Plan for ~10 minutes on a fresh clone; subsequent launches are seconds. The splash will show the wait time as "waiting for llama-server" until the model loads.

The splash window then redirects itself to `http://localhost:4000` and you see the gallery.

## Build a redistributable binary

```bash
make desktop-build
```

This installs `tauri-cli` if missing, then runs `cargo tauri build` to produce a platform-native binary in `desktop/src-tauri/target/release/bundle/`. Note: `bundle.active` is currently `false` in `tauri.conf.json` to skip icon/installer generation — flip it on once we want shippable artifacts.

## How it works

```text
desktop/
├── frontend/                       splash page shown before Phoenix is ready
│   └── index.html
├── src-tauri/                      Rust + Tauri 2.x shell
│   ├── Cargo.toml
│   ├── build.rs
│   ├── tauri.conf.json             window config, frontendDist points at ../frontend
│   ├── capabilities/
│   │   └── default.json            Tauri 2 security capabilities (core:default for now)
│   └── src/
│       └── main.rs                 lifecycle: spawn services, poll, navigate, cleanup on quit
└── README.md                       this file
```

**Boot sequence:**

1. Tauri opens the window with the splash HTML loaded from `frontend/index.html`.
2. A background thread runs `make compose-init` (idempotent — bootstraps `.env` if needed) then `docker compose --profile c2 up -d` (brings up just the ai_worker — the only container).
3. It spawns `llama-server` (vision LLM) and waits for `:11434`, then spawns the native orchestrator release (which runs migrations against the SQLite db) and waits for Phoenix on `:4000`.
4. When the port opens, the splash JS navigates to `http://localhost:4000`.
5. On window close, the shell SIGTERMs the orchestrator + llama-server children and runs `docker compose --profile c2 down` to leave the system clean.

If anything goes wrong (Docker not installed, `.env` missing required values, Phoenix doesn't come up in time), the splash page swaps in an error message instead of an infinite spinner.

## Known sharp edges

- **Splash page is static HTML.** No fancy progress bar yet. Just a "starting…" line that becomes an error string if startup fails.
- **No first-run wizard.** If `.env` isn't set up, the shell errors out with the exact compose error string. Future work: detect this and show a folder-picker UI.
- **Network-conflict path.** If something is already on port 4000, the shell will happily navigate to whatever's there. We're not yet checking `is this our Phoenix or someone else's`.
- **Quit-while-building.** If you close the window during the initial `docker compose up --build` (the slow first time), the cleanup `down` may fight the still-running build. Containers usually get cleaned up correctly anyway, but this isn't bulletproof.

These all become phase C2+ concerns once C1 has proven the shape works.
