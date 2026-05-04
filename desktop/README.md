# Fine.Shyt Desktop Shell (experimental)

> Living on branch `experimental-tauri-native`. Phase C1 of the native packaging plan — see `~/.claude/plans/qwelians-laptop-fineshyt-windows-and-doc-quiet-hanrahan.md` for the full roadmap.

A minimal Tauri 2.x shell that wraps Fine.Shyt's existing Phoenix LiveView UI in a native window. The shell is responsible for **lifecycle only** — spawning the docker-compose service stack on launch, polling for Phoenix to come up, and stopping services cleanly on quit. The UI itself is unchanged.

## Why this exists

Photographers shouldn't have to open PowerShell, run `git clone`, paste `make compose`, and remember to `docker compose down` later. They should double-click an app. This is the smallest viable shell that delivers that experience without rewriting any backend code.

## What it does NOT do (yet)

- Bundle Postgres, Phoenix, Python, or Ollama internally — those are still external. Docker is still required as a host prereq.
- Handle first-run config (PHOTO_LIBRARY, SECRET_KEY_BASE) interactively — that's still done by editing `.env` per the README. First-run wizard is a phase-2 concern.
- Code-sign or auto-update — dev builds only.

If C1 feels right, phase C2 starts replacing those pieces one at a time.

## Prerequisites

- Rust toolchain (`rustup`, `cargo`) — `cargo --version` should work.
- Node.js — only needed if you want to use `cargo tauri` CLI for production builds. Dev mode (`cargo run`) doesn't require it.
- Docker Desktop and Ollama installed on the host (same as `make compose`).
- The repo's normal `.env` set up with `PHOTO_LIBRARY` and `SECRET_KEY_BASE` (run `make compose-init` once at the repo root if you haven't).

## Run in dev mode

From the repo root:

```bash
make desktop-dev
```

This compiles the Rust shell and launches it. On first run, expect ~1 minute for Cargo to fetch and compile Tauri's deps. The window opens with a splash, then navigates to `http://localhost:4000` once Phoenix is up.

## Build a redistributable binary

```bash
make desktop-build
```

This installs `tauri-cli` if missing, then runs `cargo tauri build` to produce a platform-native binary in `desktop/src-tauri/target/release/bundle/`. Note: `bundle.active` is currently `false` in `tauri.conf.json` to skip icon/installer generation — flip it on once we want shippable artifacts.

## How it works

```
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
2. A background thread runs `make compose-init` (idempotent — bootstraps `.env` if needed) then `docker compose --profile compose up -d --build`.
3. Same thread polls `127.0.0.1:4000` via TCP every 500ms (max 120s).
4. When the port opens, the thread tells the main webview to navigate to `http://localhost:4000`.
5. On window close, the shell runs `docker compose --profile compose down` to leave the system clean.

If anything goes wrong (Docker not installed, `.env` missing required values, Phoenix doesn't come up in time), the splash page swaps in an error message instead of an infinite spinner.

## Known sharp edges

- **Splash page is static HTML.** No fancy progress bar yet. Just a "starting…" line that becomes an error string if startup fails.
- **No first-run wizard.** If `.env` isn't set up, the shell errors out with the exact compose error string. Future work: detect this and show a folder-picker UI.
- **Network-conflict path.** If something is already on port 4000, the shell will happily navigate to whatever's there. We're not yet checking `is this our Phoenix or someone else's`.
- **Quit-while-building.** If you close the window during the initial `docker compose up --build` (the slow first time), the cleanup `down` may fight the still-running build. Containers usually get cleaned up correctly anyway, but this isn't bulletproof.

These all become phase C2+ concerns once C1 has proven the shape works.
