.PHONY: dev db-up db-down setup export reset start-phoenix start-ai compose compose-init compose-up compose-down compose-build compose-logs desktop-dev desktop-build desktop-icon desktop-stage-phoenix release c2-services c2-services-down c2-run c5-llama c5-llama-stop c5-llama-logs ai-worker-launcher

CINNA  := \033[38;5;153m
KUROMI := \033[38;5;135m
KEROPPI:= \033[38;5;114m
KITTY  := \033[38;5;218m
BOLD   := \033[1m
RESET  := \033[0m

dev: db-up
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

db-up:
	@printf "$(KEROPPI)$(BOLD)"
	@printf "⠀⠀⠀⢀⡤⠤⠤⠤⣄⠀⠀⠀⠀⠀⣠⣤⣄⣀⠀⠀⠀⠀⠀\n"
	@printf "⠀⢀⡴⠉⠀⠀⠀⢀⡀⠙⣆⢀⠔⢁⣀⠀⠀⠉⠳⣄⠀⠀⠀\n"
	@printf "⠀⣾⠀⠀⠀⠀⠀⣿⣿⡇⠘⡏⠀⣿⣿⡇⠀⠀⠀⢸⡆⠀⠀\n"
	@printf "⠀⢿⡀⠀⠀⠀⠀⠉⠉⠀⢠⡇⠀⠈⠉⠀⠀⠀⠀⢰⡇⠀⠀\n"
	@printf "⠀⢨⢷⣄⠀⠀⠀⠀⢀⣴⠏⠹⣦⡀⠀⠀⠀⠀⣠⣟⠀⠀⠀\n"
	@printf "⢠⠃⠀⠈⠛⠓⠒⠚⠋⠀⠀⠀⠀⠙⠓⠒⠚⠋⠀⠈⢧⠀⠀\n"
	@printf "⢸⠀⢰⣿⣷⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢰⣿⣷⠀⢸⡇  keroppi is starting the db!\n"
	@printf "⠸⡀⠈⠛⠋⠀⣤⣀⠀⠀⠀⠀⠀⠀⢀⣠⡄⠙⠋⠀⡼⠁⠀\n"
	@printf "⠀⠹⢦⡀⠀⠀⠀⠙⠻⢶⣄⣠⣴⠾⠛⠁⠀⢀⣠⡞⠀⠀⠀\n"
	@printf "⠀⠀⠀⠈⠙⠿⠶⠶⠶⠶⠶⠶⠶⠶⠶⠖⠟⠋⠁⠀⠀⠀⠀\n"
	@printf "$(RESET)\n"
	@docker compose up -d

db-down:
	@printf "$(KUROMI)$(BOLD)"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣀⣀⣀⣀⢠⠋⠉⠉⠒⠲⢤⣀⣠⡀⠀\n"
	@printf "⠀⠀⠀⠀⠀⠀⣀⣀⣀⢀⡠⠖⠋⠉⠀⠀⠀⠀⠉⠉⠢⣄⠀⠀⠀⢀⠼⠤⠇⠀\n"
	@printf "⠀⠀⠀⣀⠔⠊⠁⠀⢨⠏⠀⠀⠀⣠⣶⣶⣦⠀⠀⠀⠀⠀⠱⣄⡴⠃⠀⠀⠀⠀\n"
	@printf "⢸⣉⠿⣁⠀⠀⠀⢀⡇⠀⠀⠀⠀⢿⣽⣿⣼⡠⠤⢄⣀⠀⠀⢱⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠑⢦⡀⢸⠀⠀⠀⡠⠒⠒⠚⠛⠉⠀⢠⣀⡌⠳⡀⡌⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⠀⠉⠉⣆⠀⢰⠁⣀⣀⠀⠀⣀⠀⠈⡽⣧⢀⡷⠁⠀⠀⠀⠀⠀⠀\n"
	@printf "⠀⠀⠀⠀⠀⡤⢄⠀⠈⠢⣸⣄⢽⣞⡂⠀⠈⠁⣀⡜⠁⣩⡷⠿⠆  fine, shutting it all down.\n"
	@printf "⠀⠀⠀⠀⢯⣁⡸⠀⠀⠀⡬⣽⣿⡀⠙⣆⡸⠛⠠⢧⠀⡿⠯⠆\n"
	@printf "⠀⠀⠀⠀⣀⡀⠀⠀⡤⠤⣵⠁⢸⣻⡤⠏⠀⠀⠀⠀⢹⠀⠀⠀⡊⠱⣀\n"
	@printf "⠀⠀⢀⠜⠀⢘⠀⠀⠱⠲⢜⣢⣤⣧⠀⠀⠀⠀⠀⢴⠇⠀⠀⠀⠧⠠⠜\n"
	@printf "⠀⠀⠘⠤⠤⠚⠀⠀⠀⠀⠀⠀⢸⠁⠁⠀⣀⠎⠀⠻⡀\n"
	@printf "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠣⣀⣀⡴⠤⠄⠴⠁\n"
	@printf "$(RESET)\n"
	@docker compose down

start-phoenix:
	@cd orchestrator && mix phx.server

start-ai:
	@cd ai_worker && uv run fastapi dev src/main.py --reload

setup: db-up
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
	@cd orchestrator && mix deps.get && mix ecto.setup
	@cd ai_worker && uv sync

reset: db-up
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
	@cd orchestrator && mix ecto.reset

## ---- Compose distribution -----------------------------------------------
##
## `make compose` is the one-command flow for self-hosters: bootstrap a .env
## with a fresh SECRET_KEY_BASE, build images, and start everything.
## PHOTO_LIBRARY is the only value the user has to fill in by hand — we
## can't guess where their photos live.

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

desktop-build: ai-worker-launcher desktop-stage-phoenix
	@printf "$(CINNA)$(BOLD)→ building desktop binary (release)...$(RESET)\n"
	@command -v cargo-tauri >/dev/null 2>&1 || \
		(printf "$(CINNA)→ installing tauri-cli (one time)...$(RESET)\n" && \
		 cargo install tauri-cli --version "^2.0" --locked)
	@cd desktop/src-tauri && cargo tauri build

# Stage the Phoenix release into desktop/runtime/phoenix/ for bundling.
# Two things this step does that a naive copy doesn't:
#   1. Skips the priv/static/uploads symlink (`ensure_uploads_symlink`
#      creates this at boot pointing at the user's photo library — Tauri's
#      resource bundling follows symlinks, so without this exclude the
#      .app would balloon by however many GB of photos the maintainer has).
#   2. rsync preserves the directory structure exactly so `bin/server`
#      stays a callable Erlang release entry point.
# Re-runs cheaply since rsync only copies changed files.
desktop-stage-phoenix: release
	@printf "$(CINNA)$(BOLD)→ staging Phoenix release into desktop/runtime/phoenix/...$(RESET)\n"
	@mkdir -p desktop/runtime/phoenix
	@rsync -a --delete \
		--exclude='lib/orchestrator-*/priv/static/uploads' \
		--exclude='lib/orchestrator-*/priv/static/uploads/' \
		orchestrator/_build/prod/rel/orchestrator/ desktop/runtime/phoenix/
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

AI_WORKER_LAUNCHER := desktop/runtime/bin/fineshyt-ai-worker
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
		mv $$TMP/bin/pyapp $@ && \
		rm -rf $$TMP
	@printf "$(KEROPPI)→ launcher ready at $@ ($$(du -sh $@ | cut -f1))$(RESET)\n"

## ---- Phase C2 — Elixir release as a local sidecar -----------------------
##
## C2 drops the orchestrator out of Docker and runs it as a native Elixir
## release on the host. db and ai_worker stay containerized (those move
## later in C3 and C4). Use `make release` to build the release artifact,
## `make c2-services` to bring up db + ai_worker, and `make c2-run` to
## start everything in one go for testing without Tauri in the loop.

release:
	@printf "$(CINNA)$(BOLD)→ building Phoenix release (MIX_ENV=prod)...$(RESET)\n"
	@cd orchestrator && \
		MIX_ENV=prod mix deps.get --only prod && \
		MIX_ENV=prod mix compile && \
		MIX_ENV=prod mix assets.deploy && \
		MIX_ENV=prod mix release --overwrite
	@printf "$(KEROPPI)$(BOLD)→ release ready at orchestrator/_build/prod/rel/orchestrator/$(RESET)\n"

c2-services:
	@printf "$(KEROPPI)$(BOLD)→ starting db + ai_worker (orchestrator runs locally in C2 mode)...$(RESET)\n"
	@docker compose --profile c2 up -d
	@docker compose --profile c2 ps

c2-services-down:
	@printf "$(KUROMI)$(BOLD)→ stopping db + ai_worker...$(RESET)\n"
	@docker compose --profile c2 down

c2-run: c2-services
	@printf "$(CINNA)$(BOLD)→ starting native orchestrator release (Ctrl+C to stop)...$(RESET)\n"
	@if [ ! -x orchestrator/_build/prod/rel/orchestrator/bin/server ]; then \
		printf "$(KUROMI)✗ release not built yet. Run 'make release' first.$(RESET)\n"; \
		exit 1; \
	fi
	@if [ ! -f .env ]; then \
		printf "$(KUROMI)✗ .env missing. Run 'make compose-init' first.$(RESET)\n"; \
		exit 1; \
	fi
	@SECRET=$$(grep '^SECRET_KEY_BASE=' .env | cut -d= -f2-); \
	if [ -z "$$SECRET" ]; then \
		printf "$(KUROMI)✗ SECRET_KEY_BASE missing in .env. Run 'make compose-init'.$(RESET)\n"; \
		exit 1; \
	fi; \
	UPLOADS=$$(pwd)/orchestrator/priv/static/uploads; \
	DATABASE_PATH="$$(pwd)/orchestrator/priv/fineshyt.db" \
	SECRET_KEY_BASE="$$SECRET" \
	PHX_HOST=localhost \
	PHX_SCHEME=http \
	PHX_URL_PORT=4000 \
	PORT=4000 \
	AI_WORKER_URL=http://localhost:8000 \
	STATIC_UPLOADS_DIR="$$UPLOADS" \
	./orchestrator/_build/prod/rel/orchestrator/bin/migrate && \
	DATABASE_PATH="$$(pwd)/orchestrator/priv/fineshyt.db" \
	SECRET_KEY_BASE="$$SECRET" \
	PHX_HOST=localhost \
	PHX_SCHEME=http \
	PHX_URL_PORT=4000 \
	PORT=4000 \
	AI_WORKER_URL=http://localhost:8000 \
	STATIC_UPLOADS_DIR="$$UPLOADS" \
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
	@cd orchestrator && mix fineshyt.export --target $(TARGET)
