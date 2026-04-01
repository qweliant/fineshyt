.PHONY: dev db-up db-down setup

# ensures the DB is running, then starts both servers.
dev: db-up
	@echo "Starting up the AI Photo Curation system..."
	@make -j 2 start-phoenix start-ai

# --- Infrastructure Commands ---
db-up:
	docker compose up -d

db-down:
	docker compose down

# --- Application Commands ---
start-phoenix:
	cd orchestrator && mix phx.server

start-ai:
	cd ai_worker && uv run fastapi dev src/main.py --reload

# --- Initial Setup (Run this once) ---
setup: db-up
	cd orchestrator && mix deps.get && mix ecto.setup
	cd ai_worker && uv sync