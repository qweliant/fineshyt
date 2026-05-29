# Orchestrator

The Elixir / Phoenix / Oban service at the heart of [Fine.Shyt](../README.md) — it owns the LiveView UI, the job queue, the database, and the real-time pub/sub fanout. The Python [ai_worker](../ai_worker/) does the ML; this service coordinates everything else.

- **DB:** SQLite (WAL mode) via `ecto_sqlite3` — since C3 there's no Postgres. CLIP embeddings are stored as a float32 blob (`Orchestrator.Embedding`); there's no in-DB vector search, so a plain blob suffices.
- **Jobs:** Oban on the Lite (SQLite) engine. Pipeline workers live in [lib/orchestrator/workers/](lib/orchestrator/workers/) — conversion, AI curation, CLIP embedding, preference train/score, burst detection.
- **Runs as:** a native Elixir release spawned by the Tauri desktop shell, or a container in the `make compose` path.

## Dev quickstart

```bash
mix setup            # deps + ecto.setup (creates the SQLite file + migrates) + assets
mix phx.server       # or: iex -S mix phx.server
```

Then visit [`localhost:4000`](http://localhost:4000). From the repo root, `make dev` runs this plus the ai_worker together.

The database file lives at `priv/orchestrator_dev.db` (dev) / `priv/orchestrator_test.db` (test). In a packaged build the path comes from `DATABASE_PATH` (defaults to a per-user data dir — see `config/runtime.exs`).

## Maintainer tasks

```bash
mix fineshyt.migrate_to_sqlite <export.jsonl>   # one-off Postgres → SQLite data import (C3)
mix fineshyt.regenerate_thumbnails              # re-convert photos whose uploads JPEG is missing
mix fineshyt.embed_backfill                     # CLIP embeddings for photos missing them
mix fineshyt.export --target /path              # blog export + photos.json manifest
```

## Learn more

- Fine.Shyt architecture + RADIO design notes: [../README.md](../README.md)
- Desktop shell + native packaging roadmap: [../desktop/README.md](../desktop/README.md)
- Phoenix: [hexdocs.pm/phoenix](https://hexdocs.pm/phoenix/overview.html)
