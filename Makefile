.PHONY: dev db-up db-down setup export reset start-phoenix start-ai compose compose-init compose-up compose-down compose-build compose-logs desktop-dev desktop-build release c2-services c2-services-down c2-run

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

desktop-dev:
	@printf "$(CINNA)$(BOLD)→ launching desktop shell in dev mode...$(RESET)\n"
	@cd desktop/src-tauri && cargo run

desktop-build:
	@printf "$(CINNA)$(BOLD)→ building desktop binary (release)...$(RESET)\n"
	@command -v cargo-tauri >/dev/null 2>&1 || \
		(printf "$(CINNA)→ installing tauri-cli (one time)...$(RESET)\n" && \
		 cargo install tauri-cli --version "^2.0" --locked)
	@cd desktop/src-tauri && cargo tauri build

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
	DATABASE_URL='ecto://postgres:postgres_password@localhost:5432/photo_curator_dev' \
	SECRET_KEY_BASE="$$SECRET" \
	PHX_HOST=localhost \
	PHX_SCHEME=http \
	PHX_URL_PORT=4000 \
	PORT=4000 \
	AI_WORKER_URL=http://localhost:8000 \
	STATIC_UPLOADS_DIR="$$UPLOADS" \
	./orchestrator/_build/prod/rel/orchestrator/bin/migrate && \
	DATABASE_URL='ecto://postgres:postgres_password@localhost:5432/photo_curator_dev' \
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
