# syntax=docker/dockerfile:1.6

# ---- Builder ---------------------------------------------------------
# Pinned to a known-good combo. Bump deliberately, not opportunistically.
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241016-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Cache deps separately from app code — most rebuilds skip this layer.
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile

# Asset toolchain (tailwind + esbuild) auto-downloads platform binaries
# via Hex packages, so no Node.js needed.
COPY assets assets
COPY priv priv
RUN mix assets.setup

COPY lib lib
RUN mix assets.deploy

# Final compile + release.
COPY config/runtime.exs config/
RUN mix compile && mix release

# ---- Runtime ---------------------------------------------------------
FROM debian:bookworm-slim AS runtime

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        libstdc++6 openssl libncurses6 locales ca-certificates tini && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PHX_SERVER=true \
    MIX_ENV=prod

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/orchestrator ./

# Migrations on every start — single-user self-hosted, idempotent, fine.
COPY <<'EOF' /app/entrypoint.sh
#!/bin/sh
set -e
echo "Running migrations..."
/app/bin/orchestrator eval "Orchestrator.Release.migrate"
echo "Starting server..."
exec /app/bin/server
EOF
RUN chmod +x /app/entrypoint.sh

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
