.PHONY: dev db-up db-down setup export reset start-phoenix start-ai compose compose-init compose-up compose-down compose-build compose-logs

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
	@docker compose up --build

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
	@if ! grep -q '^PHOTO_LIBRARY=.\+' .env; then \
		printf "$(KUROMI)$(BOLD)\n!! PHOTO_LIBRARY is empty in .env. Edit .env and set it to the folder where your photos live, then re-run.\n!! example: PHOTO_LIBRARY=$$HOME/Pictures$(RESET)\n\n"; \
		exit 1; \
	fi
	@printf "$(KEROPPI)$(BOLD)→ .env ready.$(RESET)\n"

compose-up:
	@docker compose up -d

compose-down:
	@docker compose down

compose-build:
	@docker compose build

compose-logs:
	@docker compose logs -f

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
