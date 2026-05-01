# syntax=docker/dockerfile:1.6

# python:3.12-slim — rawpy + torch wheels exist for 3.12, not yet for 3.13.
FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    UV_LINK_MODE=copy

# Native deps:
#   - libraw (rawpy backend, RAW decoding)
#   - libgl1 + libglib2.0 (some image libs link against these)
#   - build-essential (numpy/scipy compile fallback if no wheel)
#   - ca-certificates + curl (uv installer + HF model fetches)
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        libraw20 \
        libgl1 \
        libglib2.0-0 \
        build-essential \
        ca-certificates \
        curl && \
    rm -rf /var/lib/apt/lists/*

# uv is the venv/dep manager the project already uses.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv

WORKDIR /app

# Cache the dep install layer separately from source.
COPY pyproject.toml ./
COPY uv.lock* ./
RUN uv sync --frozen --no-install-project 2>/dev/null || uv sync --no-install-project

COPY src ./src
RUN uv sync

# CLIP model cache + preference model live on volumes mounted from compose.
ENV HF_HOME=/cache/huggingface \
    TRANSFORMERS_CACHE=/cache/huggingface \
    TORCH_HOME=/cache/torch

EXPOSE 8000

# fastapi run = production mode: no --reload, multi-worker via uvicorn.
CMD ["uv", "run", "fastapi", "run", "src/main.py", "--host", "0.0.0.0", "--port", "8000"]
