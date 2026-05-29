defmodule Orchestrator.Repo.Migrations.AddInsertedAtIndex do
  use Ecto.Migration

  # The default gallery view sorts by inserted_at DESC with a `curation_status
  # NOT IN (...)` filter. NOT IN isn't sargable on the leading column of the
  # composite (curation_status, inserted_at) index, so SQLite was building a
  # temp B-tree to sort all matching rows. A standalone inserted_at index lets
  # it traverse in order and stop at the page LIMIT — no sort. (The composite
  # still serves the exact-match rejected/failed views.)
  def change do
    create index(:photos, [:inserted_at])
  end
end
