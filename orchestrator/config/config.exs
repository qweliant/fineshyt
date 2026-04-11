# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :orchestrator,
  ecto_repos: [Orchestrator.Repo],
  generators: [timestamp_type: :utc_datetime]

# Register the pgvector extension with Postgrex so `%Pgvector{}` round-trips
# through the `clip_embedding vector(768)` column on the photos table.
config :orchestrator, Orchestrator.Repo, types: Orchestrator.PostgresTypes

# Configure the endpoint
config :orchestrator, OrchestratorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OrchestratorWeb.ErrorHTML, json: OrchestratorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Orchestrator.PubSub,
  live_view: [signing_salt: "6RBSOLTl"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :orchestrator, Orchestrator.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  orchestrator: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  orchestrator: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :orchestrator, Oban,
  engine: Oban.Engines.Basic,
  queues: [
    # 4 concurrent RAW→JPEG conversions (~150MB RAM each, safe on 16GB)
    conversion: 4,
    # Strictly 1 LLM call at a time — Ollama serializes anyway
    ai_jobs: 1,
    # CLIP image embeddings. One model in RAM; small concurrency avoids
    # thrashing CPU against Ollama inference on the same box.
    embedding: 2,
    # Preference model training / scoring. One job at a time — pickled
    # model on disk, no point racing retrains.
    preference: 1
  ],
  repo: Orchestrator.Repo

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
