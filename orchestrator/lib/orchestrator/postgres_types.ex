Postgrex.Types.define(
  Orchestrator.PostgresTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
