.PHONY: dev setup export reset start-phoenix start-ai start-ai-native start-release compose compose-init compose-up compose-down compose-build compose-logs desktop-dev desktop-build desktop-icon desktop-stage-phoenix release c2-run c5-llama c5-llama-stop c5-llama-logs ai-worker-launcher

## Absolute paths, resolved once. The dev targets spawn two child processes
## from different working directories (orchestrator/ and ai_worker/), and
## they have to agree on where the uploads cache and the database live —
## relative paths silently gave each one its own.
REPO_ROOT    := $(shell pwd)
DEV_UPLOADS  := $(REPO_ROOT)/orchestrator/priv/static/uploads
## An inherited DATABASE_PATH wins, so `DATABASE_PATH=/tmp/scratch.db make dev`
## (or `make reset`) points every target at the scratch file consistently —
## including the safety check in `reset`, which would otherwise report the
## real library's photo count while dropping a different database.
DEV_DB       := $(if $(DATABASE_PATH),$(DATABASE_PATH),$(REPO_ROOT)/orchestrator/priv/fineshyt.db)
## The vision LLM is optional in dev — only *new* imports call /curate.
## `make c5-llama` starts one on this port when you're ingesting.
DEV_LLM_URL  ?= http://127.0.0.1:11434/v1/

CINNA  := \033[38;5;153m
KUROMI := \033[38;5;135m
KEROPPI:= \033[38;5;114m
KITTY  := \033[38;5;218m
BOLD   := \033[1m
RESET  := \033[0m

## ---- Native dev ---------------------------------------------------------
##
## Zero Docker. Phoenix runs under `mix phx.server` (code reload) against
## priv/fineshyt.db — the same file the desktop shell and the release read,
## so dev, `make c2-run` and the .app all see one library. The ai_worker
## runs under uv with --reload.

dev:
	@printf "$(CINNA)$(BOLD)"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢎⠱⠊⡱⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡠⠤⠒⠒⠒⠒⠤⢄⣑⠁⠀⠀⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⠀⠀⢀⡤⠒⠝⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠲⢄⡀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⢀⡴⠋⠀⠀⠀⠀⣀⠀⠀⠀⠀⠀⠀⢠⣢⠐⡄⠀⠉⠑⠒⠒⠒⣄\n"
	@printf "⠀⠀⠀⣀⠴⠋⠀⠀⠀⡎⢀⣘⠿⠀⠀⢠⣀⢄⡦⠀⣛⣐⢸⠀⠀⠀⠀⠀⠀⢘\n"
	@printf "⡠⠒⠉⠀⠀⠀⠀⠀⡰⢅⠣⠤⠘⠀⠀⠀⠀⠀⠀⢀⣀⣤⡋⠙⠢⢄⣀⣀⡠⠊\n"
	@printf "⢇⠀⠀⠀⠀⠀⢀⠜⠁⠀⠉⡕⠒⠒⠒⠒⠒⠛⠉⠹⡄⣀⠘⡄   launching fine.shyt ✦\n"
	@printf "⠀⠑⠂⠤⠔⠒⠁⠀⠀⡎⠱⡃⠀⠀⡄⠀⠄⠀⠀⠠⠟⠉⡷⠁\n"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠹⠤⠤⠴⣄⡸⠤⣄⠴⠤⠴⠄⠼⠀\n"
	@printf "$(RESET)\n"
	@$(MAKE) -j 2 start-phoenix start-ai

## DATABASE_PATH is passed explicitly rather than left to config/dev.exs's
## default so that `make dev` and `make c2-run` (prod release, where dev.exs
## isn't loaded at all) provably read the same file.
start-phoenix:
	@cd orchestrator && \
		DATABASE_PATH="$(DEV_DB)" \
		STATIC_UPLOADS_DIR="$(DEV_UPLOADS)" \
		AI_WORKER_URL=http://127.0.0.1:8000 \
		mix phx.server

## STATIC_UPLOADS_DIR has to match the orchestrator's: /embed reads the
## converted JPEG back off disk by path, so a mismatch here surfaces much
## later as "embedding failed, file not found" on an otherwise fine import.
start-ai:
	@cd ai_worker && \
		STATIC_UPLOADS_DIR="$(DEV_UPLOADS)" \
		LLM_BASE_URL="$(DEV_LLM_URL)" \
		uv run fastapi dev src/main.py --port 8000

setup:
	@printf "$(CINNA)$(BOLD)"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢎⠱⠊⡱⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡠⠤⠒⠒⠒⠒⠤⢄⣑⠁⠀⠀⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⠀⠀⢀⡤⠒⠝⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠲⢄⡀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⢀⡴⠋⠀⠀⠀⠀⣀⠀⠀⠀⠀⠀⠀⢠⣢⠐⡄⠀⠉⠑⠒⠒⠒⣄\n"
	@printf "⠀⠀⠀⣀⠴⠋⠀⠀⠀⡎⢀⣘⠿⠀⠀⢠⣀⢄⡦⠀⣛⣐⢸⠀⠀⠀⠀⠀⠀⢘\n"
	@printf "⡠⠒⠉⠀⠀⠀⠀⠀⡰⢅⠣⠤⠘⠀⠀⠀⠀⠀⠀⢀⣀⣤⡋⠙⠢⢄⣀⣀⡠⠊\n"
	@printf "⢇⠀⠀⠀⠀⠀⢀⠜⠁⠀⠉⡕⠒⠒⠒⠒⠒⠛⠉⠹⡄⣀⠘⡄   setting everything up!\n"
	@printf "⠀⠑⠂⠤⠔⠒⠁⠀⠀⡎⠱⡃⠀⠀⡄⠀⠄⠀⠀⠠⠟⠉⡷⠁\n"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠹⠤⠤⠴⣄⡸⠤⣄⠴⠤⠴⠄⠼⠀\n"
	@printf "$(RESET)\n"
	@cd orchestrator && DATABASE_PATH="$(DEV_DB)" mix deps.get && DATABASE_PATH="$(DEV_DB)" mix ecto.setup
	@cd ai_worker && uv sync
	@printf "$(KEROPPI)$(BOLD)→ ready. 'make dev' to start.$(RESET)\n"

## Guarded since dev moved onto the real library: `mix ecto.reset` is
## ecto.drop + ecto.setup, so an absent-minded `make reset` used to cost a
## 73 KB scratch file and now costs every rating, embedding and preference
## score in fineshyt.db. Requires CONFIRM=1 and prints what's at stake.
reset:
	@if [ "$(CONFIRM)" != "1" ]; then \
		COUNT=$$(sqlite3 "$(DEV_DB)" 'select count(*) from photos' 2>/dev/null || echo '?'); \
		RATED=$$(sqlite3 "$(DEV_DB)" 'select count(*) from photos where user_rating is not null' 2>/dev/null || echo '?'); \
		printf "$(KUROMI)$(BOLD)\n"; \
		printf "!! 'make reset' DROPS $(DEV_DB)\n"; \
		printf "!! that database holds $$COUNT photos, $$RATED of them rated.\n"; \
		printf "!! there is no undo. back up first:  ./scripts/backup.sh\n\n"; \
		printf "$(RESET)"; \
		printf "if you meant it:            make reset CONFIRM=1\n"; \
		printf "scratch db instead:         DATABASE_PATH=/tmp/scratch.db make reset CONFIRM=1\n"; \
		exit 1; \
	fi
	@printf "$(KUROMI)$(BOLD)"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣀⣀⣀⣀⢠⠋⠉⠉⠒⠲⢤⣀⣠⡀⠀\n"
	@printf "⠀⠀⠀⠀⠀⠀⣀⣀⣀⢀⡠⠖⠋⠉⠀⠀⠀⠀⠉⠉⠢⣄⠀⠀⠀⢀⠼⠤⠇⠀\n"
	@printf "⠀⠀⠀⣀⠔⠊⠁⠀⢨⠏⠀⠀⠀⣠⣶⣶⣦⠀⠀⠀⠀⠀⠱⣄⡴⠃⠀⠀⠀⠀\n"
	@printf "⢸⣉⠿⣁⠀⠀⠀⢀⡇⠀⠀⠀⠀⢿⣽⣿⣼⡠⠤⢄⣀⠀⠀⢱⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠑⢦⡀⢸⠀⠀⠀⡠⠒⠒⠚⠛⠉⠀⢠⣀⡌⠳⡀⡌⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⠀⠉⠉⣆⠀⢰⠁⣀⣀⠀⠀⣀⠀⠈⡽⣧⢀⡷⠁⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⡤⢄⠀⠈⠢⣸⣄⢽⣞⡂⠀⠈⠁⣀⡜⠁⣩⡷⠿⠆  wiping everything. starting fresh.\n"
	@printf "⠀⠀⠀⠀⢯⣁⡸⠀⠀⠀⡬⣽⣿⡀⠙⣆⡸⠛⠠⢧⠀⡿⠯⠆\n"
	@printf "⠀⠀⠀⠀⣀⡀⠀⠀⡤⠤⣵⠁⢸⣻⡤⠏⠀⠀⠀⠀⢹⠀⠀⠀⡊⠱⣀\n"
	@printf "⠀⠀⢀⠜⠀⢘⠀⠀⠱⠲⢜⣢⣤⣧⠀⠀⠀⠀⠀⢴⠇⠀⠀⠀⠧⠠⠜\n"
	@printf "⠀⠀⠘⠤⠤⠚⠀⠀⠀⠀⠀⠀⢸⠁⠁⠀⣀⠎⠀⠻⡀\n"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠣⣀⣀⡴⠤⠄⠴⠁\n"
	@printf "$(RESET)\n"
	@cd orchestrator && DATABASE_PATH="$(DEV_DB)" mix ecto.reset

## ---- Compose distribution (legacy, self-hosters only) -------------------
##
## Nothing below here is part of the dev or desktop path any more — dev is
## native (`make dev`), the desktop shell spawns its children directly, and
## the ai_worker ships as a PyApp launcher. These targets remain for
## self-hosters who want the whole stack in containers on a box that isn't
## this laptop. Docker is required for these and only these.
##
## `make compose` is the one-command flow: bootstrap a .env with a fresh
## SECRET_KEY_BASE, build images, and start everything. PHOTO_LIBRARY is the
## only value the user has to fill in by hand — we can't guess where their
## photos live.

compose: compose-init
	@docker compose --profile compose up --build

compose-init:
	@if [ ! -f .env ]; then \
		printf "$(CINNA)$(BOLD)→ creating .env from .env.example...$(RESET)\n"; \
		cp .env.example .env; \
	fi
	@if ! grep -q '^SECRET_KEY_BASE=.\+' .env; then \
		printf "$(CINNA)$(BOLD)→ generating SECRET_KEY_BASE...$(RESET)\n"; \
		SECRET=$$(cd orchestrator && mix phx.gen.secret 2>/dev/null || openssl rand -base64 48 | tr -d '\n'); \
		if [ -z "$$SECRET" ]; then \
			printf "$(KUROMI)✗ couldn't generate a secret. install elixir/openssl or set SECRET_KEY_BASE manually in .env$(RESET)\n"; \
			exit 1; \
		fi; \
		case "$$(uname -s)" in \
			Darwin) sed -i '' "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$$SECRET|" .env ;; \
			*)      sed -i    "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$$SECRET|" .env ;; \
		esac; \
	fi
	@# Multi-drive mode: if PHOTO_LIBRARIES is set, auto-fill PHOTO_LIBRARY
	@# from the first entry so the base compose file's `${PHOTO_LIBRARY:?}`
	@# validation passes, then generate the override file.
	@if grep -q '^PHOTO_LIBRARIES=.\+' .env && ! grep -q '^PHOTO_LIBRARY=.\+' .env; then \
		FIRST=$$(grep -E '^PHOTO_LIBRARIES=' .env | head -1 | cut -d= -f2- | cut -d: -f1); \
		printf "$(CINNA)$(BOLD)→ auto-filling PHOTO_LIBRARY from PHOTO_LIBRARIES[0]: $$FIRST$(RESET)\n"; \
		case "$$(uname -s)" in \
			Darwin) sed -i '' "s|^PHOTO_LIBRARY=.*|PHOTO_LIBRARY=$$FIRST|" .env ;; \
			*)      sed -i    "s|^PHOTO_LIBRARY=.*|PHOTO_LIBRARY=$$FIRST|" .env ;; \
		esac; \
	fi
	@if ! grep -q '^PHOTO_LIBRARY=.\+' .env; then \
		printf "$(KUROMI)$(BOLD)\n!! No photo paths configured. Edit .env and set ONE of:\n!!   PHOTO_LIBRARY=$$HOME/Pictures                                  (one drive)\n!!   PHOTO_LIBRARIES=/Volumes/DriveA:/Volumes/DriveB                (multiple)\n$(RESET)\n"; \
		exit 1; \
	fi
	@./scripts/generate-compose-override.sh
	@printf "$(KEROPPI)$(BOLD)→ .env ready.$(RESET)\n"

compose-up:
	@docker compose --profile compose up -d

compose-down:
	@docker compose --profile compose down

compose-build:
	@docker compose --profile compose build

compose-logs:
	@docker compose --profile compose logs -f

## ---- Desktop shell (experimental, phase C1) -----------------------------
##
## A minimal Tauri 2.x window that wraps the Phoenix LiveView UI. The shell
## handles lifecycle only — it spawns `make compose` on launch, polls until
## :4000 answers, then navigates the webview to localhost:4000. On quit it
## runs `docker compose down` to leave the system clean. Backend code is
## unchanged. See desktop/README.md for the full picture and the C2+
## roadmap.

## `cargo run` boots the Tauri shell, which spawns the **staged Phoenix
## release** at `desktop/runtime/phoenix/bin/server` — not `mix phx.server`.
## That means any change you make to .ex / .heex files only takes effect
## after `make desktop-stage-phoenix` (or `make release`) re-runs. Kept
## out of the dep chain on purpose — you remember to do this; we don't
## want a multi-second mix release fired on every dev relaunch.
desktop-dev: ai-worker-launcher desktop-kill-orphans
	@printf "$(KITTY)$(BOLD)"
	@printf "⠀⠀⠀⢠⡾⠲⠶⣤⣀⣠⣤⣤⣤⡿⠛⠿⡴⠾⠛⢻⡆⠀⠀⠀\n"
	@printf "⠀⠀⠀⣼⠁⠀⠀⠀⠉⠁⠀⢀⣿⠐⡿⣿⠿⣶⣤⣤⣷⡀⠀⠀\n"
	@printf "⠀⠀⠀⢹⡶⠀⠀⠀⠀⠀⠀⠌⢯⣡⣿⣿⣀⣸⣿⣦⢓⡟⠀⠀\n"
	@printf "⠀⠀⢀⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠹⣍⣭⣾⠁⠀⠀\n"
	@printf "⠀⣀⣸⣇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣸⣷⣤⡀\n"
	@printf "⠈⠉⠹⣏⡁⠀⢸⣿⠀⠀⠀⠀⠀⠀⠀⠀⣿⡇⠀⢀⣸⣇⣀⠀\n"
	@printf "⠀⠐⠋⢻⣅⣄⢀⣀⣀⡀⠀⠯⠽⠀⢀⣀⣀⡀⠀⣤⣿⠀⠉⠀  kitty is launching the desktop shell ✦\n"
	@printf "⠀⠀⠴⠛⠙⣳⠋⠉⠉⠙⣆⠀⠀⢰⡟⠉⠈⠙⢷⠟⠉⠙⠂⠀  (Tauri/WKWebView takes ~30s on a cold launch)\n"
	@printf "⠀⠀⠀⠀⠀⢻⣄⣠⣤⣴⠟⠛⠛⠛⢧⣤⣤⣀⡾⠀⠀⠀⠀⠀\n"
	@printf "$(RESET)\n"
	@cd desktop/src-tauri && cargo run

# Kill leftover processes from a previous bundled .app run or a crashed dev
# shell. The bundled Tauri shell can die without taking its child Phoenix
# release + ai_worker + llama-server down with it — those get adopted by
# launchd and silently keep holding :4000/:8000/:11434. When dev fires up
# next, its own children either fail to bind or the webview connects to the
# orphaned BEAM (which points at the bundled app's empty user-data DB), so
# you see "0 photos" against your real 12k-photo dev library.
desktop-kill-orphans:
	@pkill -9 -f 'Fine\.Shyt\.app|Fineshyt\.app|fineshyt-ai-worker|fineshyt_ai\.serve|llama-server|/phoenix/erts.*beam\.smp' 2>/dev/null || true
	@lsof -ti:4000 -i:8000 -i:11434 2>/dev/null | xargs -r kill -9 2>/dev/null || true

desktop-build: ai-worker-launcher desktop-stage-phoenix desktop-stage-llama
	@printf "$(CINNA)$(BOLD)→ building desktop binary (release)...$(RESET)\n"
	@command -v cargo-tauri >/dev/null 2>&1 || \
		(printf "$(CINNA)→ installing tauri-cli (one time)...$(RESET)\n" && \
		 cargo install tauri-cli --version "^2.0" --locked)
	@cd desktop/src-tauri && cargo tauri build

# Download a prebuilt `llama-server` for the host platform from ggml-org's
# releases and drop it at desktop/runtime/bin/. This is Phase 2 of the
# distribution work: bundling llama-server inside the .app/.msi/.AppImage
# removes the `brew install llama.cpp` prereq for users (Mac) and is the
# only way to ship to Windows (no equivalent package manager).
#
# Pinning a specific build (`LLAMA_VERSION`) keeps the artifact reproducible
# across machines and across time. Bump when you want a newer llama.cpp
# (vision-model support gets better release over release). Override on the
# command line: `make desktop-stage-llama LLAMA_VERSION=b6800`.
#
# Asset naming matches ggml-org's convention as of 2026:
#   * Darwin arm64  → llama-<ver>-bin-macos-arm64.zip
#   * Darwin x86_64 → llama-<ver>-bin-macos-x64.zip
#   * Linux  x86_64 → llama-<ver>-bin-ubuntu-x64.zip
# Windows is downloaded from the CI workflow directly (no make on a fresh
# Windows runner; PowerShell does the unzipping).
LLAMA_VERSION       ?= b6500
LLAMA_DIR           := desktop/runtime/bin/llama
LLAMA_SERVER        := $(LLAMA_DIR)/llama-server
LLAMA_VERSION_FILE  := $(LLAMA_DIR)/.version

desktop-stage-llama: $(LLAMA_SERVER)

# Extract the whole llama.cpp `bin/` directory (binary + dynamic libs) into
# desktop/runtime/bin/llama/. The bundled binary's rpath looks for dylibs
# alongside itself, so we have to ship the dependencies as a unit — copying
# just `llama-server` results in `Library not loaded: @rpath/libmtmd.dylib`
# at first launch.
$(LLAMA_SERVER): $(LLAMA_VERSION_FILE)
	@mkdir -p $(LLAMA_DIR)
	@OS=$$(uname -s); ARCH=$$(uname -m); \
	case "$$OS-$$ARCH" in \
		Darwin-arm64)  ASSET="llama-$(LLAMA_VERSION)-bin-macos-arm64.zip" ;; \
		Darwin-x86_64) ASSET="llama-$(LLAMA_VERSION)-bin-macos-x64.zip" ;; \
		Linux-x86_64)  ASSET="llama-$(LLAMA_VERSION)-bin-ubuntu-x64.zip" ;; \
		*) printf "$(KUROMI)✗ unsupported host platform for llama-server staging: $$OS-$$ARCH$(RESET)\n"; exit 1 ;; \
	esac; \
	URL="https://github.com/ggml-org/llama.cpp/releases/download/$(LLAMA_VERSION)/$$ASSET"; \
	printf "$(CINNA)$(BOLD)→ downloading llama-server $(LLAMA_VERSION) for $$OS-$$ARCH$(RESET)\n"; \
	printf "$(CINNA)  $$URL$(RESET)\n"; \
	TMP=$$(mktemp -d) && cd "$$TMP" && \
		curl -fsSL "$$URL" -o llama.zip && \
		unzip -q llama.zip && \
		BIN_DIR=$$(find . -type d -name 'bin' | head -1) && \
		[ -n "$$BIN_DIR" ] || BIN_DIR=$$(find . -name 'llama-server' -type f | head -1 | xargs dirname) && \
		[ -n "$$BIN_DIR" ] || (printf "$(KUROMI)✗ llama-server not found inside $$ASSET$(RESET)\n"; exit 1) && \
		cp -R "$$BIN_DIR/." "$(CURDIR)/$(LLAMA_DIR)/" && \
		chmod +x "$(CURDIR)/$(LLAMA_SERVER)" && \
		rm -rf "$$TMP"
	@printf "$(KEROPPI)→ llama runtime staged at $(LLAMA_DIR) ($$(du -sh $(LLAMA_DIR) | cut -f1))$(RESET)\n"

# Sentinel that tracks the currently-staged version so a `LLAMA_VERSION` bump
# triggers a re-download. The recipe both writes the file AND deletes any
# stale binary so the next $(LLAMA_SERVER) rule runs cleanly.
$(LLAMA_VERSION_FILE):
	@mkdir -p $(LLAMA_DIR)
	@if [ -f $@ ] && [ "$$(cat $@)" = "$(LLAMA_VERSION)" ]; then \
		touch $@; \
	else \
		printf "$(CINNA)→ llama-server version pin changed → $(LLAMA_VERSION)$(RESET)\n"; \
		rm -rf $(LLAMA_DIR); \
		mkdir -p $(LLAMA_DIR); \
		echo $(LLAMA_VERSION) > $@; \
	fi

# Stage the Phoenix release into desktop/runtime/phoenix/ for bundling.
# Two things this step does that a naive copy doesn't:
#   1. Skips the priv/static/uploads symlink (`ensure_uploads_symlink`
#      creates this at boot pointing at the user's photo library — Tauri's
#      resource bundling follows symlinks, so without this exclude the
#      .app would balloon by however many GB of photos the maintainer has).
#   2. Preserves the directory structure exactly so `bin/server` stays a
#      callable Erlang release entry point.
#
# Platform split:
#   * macOS / Linux: rsync (incremental, symlink-aware, exact behaviour).
#   * Windows (Git Bash on CI): rsync isn't installed; fall back to a
#     clean-and-copy via `cp -R` + post-delete of the uploads dir. We can
#     get away with this on Windows because the symlink case doesn't
#     arise — CI builds from a fresh checkout where the uploads symlink
#     was never created.
desktop-stage-phoenix: release
	@printf "$(CINNA)$(BOLD)→ staging Phoenix release into desktop/runtime/phoenix/...$(RESET)\n"
	@mkdir -p desktop/runtime/phoenix
	@case "$$(uname -s)" in \
		MINGW*|MSYS*|CYGWIN*) \
			chmod -R +w desktop/runtime/phoenix 2>/dev/null || true; \
			rm -rf desktop/runtime/phoenix && \
			mkdir -p desktop/runtime/phoenix && \
			tar -C orchestrator/_build/prod/rel/orchestrator \
				--exclude='lib/orchestrator-*/priv/static/uploads' \
				--exclude='lib/orchestrator-*/priv/static/uploads/*' \
				-cf - . | tar -C desktop/runtime/phoenix -xf - ;; \
		*) \
			rsync -a --delete \
				--exclude='lib/orchestrator-*/priv/static/uploads' \
				--exclude='lib/orchestrator-*/priv/static/uploads/' \
				orchestrator/_build/prod/rel/orchestrator/ desktop/runtime/phoenix/ ;; \
	esac
	@printf "$(KEROPPI)→ staged: $$(du -sh desktop/runtime/phoenix | cut -f1)$(RESET)\n"

# Regenerates desktop/src-tauri/icons/{32,128,128@2x,icon.icns,icon.ico,...}
# from desktop/src-tauri/icons/source.svg. The SVG is "FS" in the title's
# brand styling. Rasterises via macOS's built-in qlmanage (WebKit) then
# delegates to `cargo tauri icon` for the full bundle.icon set.
#
# Note: the desktop dock/window icon in DEV mode comes from macOS's default
# for unbundled binaries — these assets only take effect on `make
# desktop-build` once bundle.active is flipped to true in tauri.conf.json.
desktop-icon:
	@command -v qlmanage >/dev/null 2>&1 || \
		(printf "$(KUROMI)✗ qlmanage not found (macOS-only). Render desktop/src-tauri/icons/source.svg to a 1024x1024 PNG some other way.$(RESET)\n"; exit 1)
	@printf "$(CINNA)$(BOLD)→ rasterising source.svg to 1024x1024 PNG via qlmanage...$(RESET)\n"
	@rm -f /tmp/source.svg.png
	@qlmanage -t -s 1024 desktop/src-tauri/icons/source.svg -o /tmp >/dev/null 2>&1
	@mv /tmp/source.svg.png /tmp/fineshyt-icon-source.png
	@command -v cargo-tauri >/dev/null 2>&1 || \
		(printf "$(CINNA)→ installing tauri-cli (one time)...$(RESET)\n" && \
		 cargo install tauri-cli --version "^2.0" --locked)
	@printf "$(CINNA)$(BOLD)→ generating icon set via cargo tauri icon...$(RESET)\n"
	@cd desktop/src-tauri && cargo tauri icon /tmp/fineshyt-icon-source.png
	@rm -f /tmp/fineshyt-icon-source.png
	@printf "$(KEROPPI)→ icons regenerated in desktop/src-tauri/icons/$(RESET)\n"
	@printf "$(KEROPPI)  (dev mode still shows the macOS default icon for unbundled binaries;$(RESET)\n"
	@printf "$(KEROPPI)   the new icon takes effect on 'make desktop-build' bundles.)$(RESET)\n"

## ---- Phase C5 — embedded vision LLM via llama.cpp ----------------------
##
## Runs `llama-server` (from `brew install llama.cpp`) with a vision model
## from ggml-org's HuggingFace collection. Replaces Ollama as the LLM
## the ai_worker calls. The model + mmproj download into desktop/runtime/
## models/ on first launch (~5–7 GB for Qwen2.5-Omni-7B).
##
## Notes:
##   * --no-jinja is REQUIRED for multimodal models. The default Jinja
##     chat template doesn't insert image markers, which causes a
##     "number of bitmaps does not match number of markers" tokenize
##     failure on the first vision request.
##   * -c 8192 raises the context window above the default 2048 so
##     instructor's retry-with-error chain fits.
##   * Listening on :11434 to match Ollama's port, so existing
##     LLM_BASE_URL=http://localhost:11434/v1/ keeps working with no
##     orchestrator changes.

C5_MODEL ?= ggml-org/Qwen2.5-Omni-7B-GGUF
C5_PORT  ?= 11434
C5_CTX   ?= 8192
C5_LOG   ?= /tmp/fineshyt-llama-server.log
C5_PID   ?= /tmp/fineshyt-llama-server.pid

c5-llama:
	@if [ -f $(C5_PID) ] && kill -0 $$(cat $(C5_PID)) 2>/dev/null; then \
		printf "$(KEROPPI)$(BOLD)→ llama-server already running (pid $$(cat $(C5_PID)))$(RESET)\n"; \
		exit 0; \
	fi
	@command -v llama-server >/dev/null 2>&1 || \
		(printf "$(KUROMI)✗ llama-server not found. Run 'brew install llama.cpp'.$(RESET)\n"; exit 1)
	@mkdir -p desktop/runtime/models
	@printf "$(KEROPPI)$(BOLD)"
	@printf "⠀⠀⠀⢀⡤⠤⠤⠤⣄⠀⠀⠀⠀⠀⣠⣤⣄⣀⠀⠀⠀⠀⠀\n"
	@printf "⠀⢀⡴⠉⠀⠀⠀⢀⡀⠙⣆⢀⠔⢁⣀⠀⠀⠉⠳⣄⠀⠀⠀\n"
	@printf "⠀⣾⠀⠀⠀⠀⠀⣿⣿⡇⠘⡏⠀⣿⣿⡇⠀⠀⠀⢸⡆⠀⠀\n"
	@printf "⠀⢿⡀⠀⠀⠀⠀⠉⠉⠀⢠⡇⠀⠈⠉⠀⠀⠀⠀⢰⡇⠀⠀\n"
	@printf "⠀⢨⢷⣄⠀⠀⠀⠀⢀⣴⠏⠹⣦⡀⠀⠀⠀⠀⣠⣟⠀⠀⠀\n"
	@printf "⢠⠃⠀⠈⠛⠓⠒⠚⠋⠀⠀⠀⠀⠙⠓⠒⠚⠋⠀⠈⢧⠀⠀\n"
	@printf "⢸⠀⢰⣿⣷⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢰⣿⣷⠀⢸⡇  keroppi is waking up the vision model!\n"
	@printf "⠸⡀⠈⠛⠋⠀⣤⣀⠀⠀⠀⠀⠀⠀⢀⣠⡄⠙⠋⠀⡼⠁⠀  (first run downloads ~5-7GB)\n"
	@printf "⠀⠹⢦⡀⠀⠀⠀⠙⠻⢶⣄⣠⣴⠾⠛⠁⠀⢀⣠⡞⠀⠀⠀\n"
	@printf "⠀⠀⠀⠈⠙⠿⠶⠶⠶⠶⠶⠶⠶⠶⠶⠖⠟⠋⠁⠀⠀⠀⠀\n"
	@printf "$(RESET)\n"
	@printf "$(CINNA)$(BOLD)→ starting llama-server with $(C5_MODEL) on :$(C5_PORT)...$(RESET)\n"
	@LLAMA_CACHE=$$(pwd)/desktop/runtime/models nohup \
		llama-server -hf $(C5_MODEL) \
			--port $(C5_PORT) --host 127.0.0.1 \
			--no-jinja \
			-c $(C5_CTX) \
		> $(C5_LOG) 2>&1 & \
	echo $$! > $(C5_PID)
	@printf "$(KEROPPI)→ spawned pid $$(cat $(C5_PID)), tail logs with 'make c5-llama-logs'$(RESET)\n"

c5-llama-stop:
	@if [ -f $(C5_PID) ] && kill -0 $$(cat $(C5_PID)) 2>/dev/null; then \
		PID=$$(cat $(C5_PID)); \
		kill $$PID; \
		rm -f $(C5_PID); \
		printf "$(KUROMI)→ stopped llama-server (pid $$PID)$(RESET)\n"; \
	else \
		printf "$(KUROMI)→ llama-server not running$(RESET)\n"; \
		rm -f $(C5_PID); \
	fi

c5-llama-logs:
	@tail -f $(C5_LOG)

## ---- Phase C4 — native ai_worker via PyApp launcher --------------------
##
## C4 replaces the containerised ai_worker with a PyApp launcher: a ~3 MB
## Rust binary that bootstraps a per-user Python venv + the FastAPI worker
## on first run (pip-installs ~1 GB of deps into
## ~/Library/Application Support/pyapp/), then re-execs that venv on
## subsequent launches. The desktop shell spawns this binary directly —
## no Docker.
##
## Build flow:
##   1. `uv build --wheel` — produces dist/ai_worker-X.Y.Z-py3-none-any.whl
##      (just our 27 KB of source; deps come from PyPI at install time).
##   2. `cargo install pyapp` with PYAPP_PROJECT_PATH pointing at that
##      wheel — compiles a Rust launcher that embeds the wheel + a config
##      pointing at `fineshyt_ai.serve:main` as the entry.
##   3. Move the launcher into desktop/runtime/bin/.

# Binary extension. On MSYS2 / Git Bash for Windows (used by the Windows CI
# runner via `shell: bash`), `cargo install` emits `pyapp.exe`. Detect via
# uname so the local Mac / Linux build still drops a plain `fineshyt-ai-worker`.
AI_WORKER_EXE     := $(if $(findstring MINGW,$(shell uname -s 2>/dev/null))$(findstring MSYS,$(shell uname -s 2>/dev/null)),.exe,)
AI_WORKER_LAUNCHER := desktop/runtime/bin/fineshyt-ai-worker$(AI_WORKER_EXE)
AI_WORKER_VERSION  := 0.1.0
AI_WORKER_WHEEL    := ai_worker/dist/ai_worker-$(AI_WORKER_VERSION)-py3-none-any.whl
# Wheel-affecting source. make uses these mtimes to decide whether to rebuild,
# so make ai-worker-launcher (and `make desktop-dev` which depends on it) is
# a no-op when nothing changed — fixes the previous "always rebuilds" bug
# where the recipe's early-exit `exit 0` couldn't actually short-circuit
# subsequent recipe lines (each `@line` is a fresh shell in make).
AI_WORKER_SOURCES  := $(shell find ai_worker/src/fineshyt_ai -name '*.py' 2>/dev/null) ai_worker/pyproject.toml ai_worker/uv.lock

ai-worker-launcher: $(AI_WORKER_LAUNCHER)

$(AI_WORKER_WHEEL): $(AI_WORKER_SOURCES)
	@command -v uv >/dev/null 2>&1 || \
		(printf "$(KUROMI)✗ uv not found. Install with 'curl -LsSf https://astral.sh/uv/install.sh | sh'.$(RESET)\n"; exit 1)
	@printf "$(CINNA)$(BOLD)→ building ai_worker wheel...$(RESET)\n"
	@cd ai_worker && uv build --wheel >/dev/null
	@touch $@

$(AI_WORKER_LAUNCHER): $(AI_WORKER_WHEEL)
	@command -v cargo >/dev/null 2>&1 || \
		(printf "$(KUROMI)✗ cargo not found. Install Rust from rustup.rs.$(RESET)\n"; exit 1)
	@mkdir -p $(dir $@)
	@printf "$(CINNA)$(BOLD)→ compiling PyApp launcher (Rust, ~45s first time)...$(RESET)\n"
	@TMP=$$(mktemp -d) && \
		PYAPP_PROJECT_NAME=ai_worker \
		PYAPP_PROJECT_VERSION=$(AI_WORKER_VERSION) \
		PYAPP_PROJECT_PATH=$$(pwd)/$(AI_WORKER_WHEEL) \
		PYAPP_EXEC_SPEC=fineshyt_ai.serve:main \
		PYAPP_UV_ENABLED=1 \
		cargo install pyapp --force --quiet --root $$TMP && \
		mv $$TMP/bin/pyapp$(AI_WORKER_EXE) $@ && \
		rm -rf $$TMP
	@printf "$(KEROPPI)→ launcher ready at $@ ($$(du -sh $@ | cut -f1))$(RESET)\n"

## ---- Release path (was phase C2) ----------------------------------------
##
## The orchestrator as a native Elixir release, which is what the desktop
## shell actually spawns. `make c2-run` exercises that exact path without
## Tauri in the loop — useful when a bug reproduces in the .app but not
## under `make dev` (prod config, no code reloader, digested assets).
##
## C3 (SQLite) and C4 (PyApp launcher) landed, so the old `c2-services`
## container step is gone: this runs the same native ai_worker binary the
## bundled app does.

release:
	@printf "$(CINNA)$(BOLD)→ building Phoenix release (MIX_ENV=prod)...$(RESET)\n"
	@cd orchestrator && \
		MIX_ENV=prod mix deps.get --only prod && \
		MIX_ENV=prod mix compile && \
		MIX_ENV=prod mix assets.deploy && \
		MIX_ENV=prod mix release --overwrite
	@printf "$(KEROPPI)$(BOLD)→ release ready at orchestrator/_build/prod/rel/orchestrator/$(RESET)\n"

## Runs the release and the native ai_worker side by side, same as `dev`.
c2-run: ai-worker-launcher
	@$(MAKE) -j 2 start-release start-ai-native

## The PyApp launcher rather than `uv run`: this target is here to mimic the
## bundled app, and the bundled app has no uv.
start-ai-native:
	@STATIC_UPLOADS_DIR="$(DEV_UPLOADS)" \
	 AI_WORKER_HOST=127.0.0.1 \
	 AI_WORKER_PORT=8000 \
	 LLM_BASE_URL="$(DEV_LLM_URL)" \
	 $(AI_WORKER_LAUNCHER)

start-release:
	@printf "$(CINNA)$(BOLD)→ starting native orchestrator release (Ctrl+C to stop)...$(RESET)\n"
	@if [ ! -x orchestrator/_build/prod/rel/orchestrator/bin/server ]; then \
		printf "$(KUROMI)✗ release not built yet. Run 'make release' first.$(RESET)\n"; \
		exit 1; \
	fi
	@# SECRET_KEY_BASE: reuse .env's if there is one, otherwise mint an
	@# ephemeral one. Only effect of a fresh secret on a single-user local
	@# tool is that the LiveView session cookie is re-issued, so there's no
	@# reason to make this a hard prerequisite the way the compose path did.
	@SECRET=$$([ -f .env ] && grep '^SECRET_KEY_BASE=' .env | cut -d= -f2- || true); \
	if [ -z "$$SECRET" ]; then \
		printf "$(CINNA)→ no SECRET_KEY_BASE in .env, using an ephemeral one$(RESET)\n"; \
		SECRET=$$(cd orchestrator && mix phx.gen.secret 2>/dev/null || openssl rand -base64 48 | tr -d '\n'); \
	fi; \
	export SECRET_KEY_BASE="$$SECRET" \
		DATABASE_PATH="$(DEV_DB)" \
		STATIC_UPLOADS_DIR="$(DEV_UPLOADS)" \
		AI_WORKER_URL=http://127.0.0.1:8000 \
		PHX_HOST=localhost PHX_SCHEME=http PHX_URL_PORT=4000 PORT=4000; \
	./orchestrator/_build/prod/rel/orchestrator/bin/migrate && \
	./orchestrator/_build/prod/rel/orchestrator/bin/server

export:
	@printf "$(KITTY)$(BOLD)"
	@printf "⠀⠀⠀⢠⡾⠲⠶⣤⣀⣠⣤⣤⣤⡿⠛⠿⡴⠾⠛⢻⡆⠀⠀⠀\n"
	@printf "⠀⠀⠀⣼⠁⠀⠀⠀⠉⠁⠀⢀⣿⠐⡿⣿⠿⣶⣤⣤⣷⡀⠀⠀\n"
	@printf "⠀⠀⠀⢹⡶⠀⠀⠀⠀⠀⠀⠌⢯⣡⣿⣿⣀⣸⣿⣦⢓⡟⠀⠀\n"
	@printf "⠀⠀⢀⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠉⠹⣍⣭⣾⠁⠀⠀\n"
	@printf "⠀⣀⣸⣇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣸⣷⣤⡀\n"
	@printf "⠈⠉⠹⣏⡁⠀⢸⣿⠀⠀⠀⠀⠀⠀⠀⠀⣿⡇⠀⢀⣸⣇⣀⠀\n"
	@printf "⠀⠐⠋⢻⣅⣄⢀⣀⣀⡀⠀⠯⠽⠀⢀⣀⣀⡀⠀⣤⣿⠀⠉⠀  exporting approved photos...\n"
	@printf "⠀⠀⠴⠛⠙⣳⠋⠉⠉⠙⣆⠀⠀⢰⡟⠉⠈⠙⢷⠟⠉⠙⠂⠀\n"
	@printf "⠀⠀⠀⠀⠀⢻⣄⣠⣤⣴⠟⠛⠛⠛⢧⣤⣤⣀⡾⠀⠀⠀⠀⠀\n"
	@printf "$(RESET)\n"
	@cd orchestrator && DATABASE_PATH="$(DEV_DB)" mix fineshyt.export --target $(TARGET)
