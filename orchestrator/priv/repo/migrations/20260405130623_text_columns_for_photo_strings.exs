defmodule Orchestrator.Repo.Migrations.TextColumnsForPhotoStrings do
  use Ecto.Migration

  # LLM outputs regularly exceed varchar(255). Promote all free-text fields to
  # unbounded :text so truncation errors never surface again.
  #
  # SQLite has no ALTER COLUMN and doesn't enforce string length anyway —
  # every TEXT/VARCHAR column is already unbounded — so this is a no-op there.
  # The `modify` only matters on Postgres, where varchar(255) is enforced.
  def change do
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      alter table(:photos) do
        modify :subject, :text
        modify :artistic_mood, :text
        modify :lighting_critique, :text
        modify :style_reason, :text
      end
    end
  end
end
