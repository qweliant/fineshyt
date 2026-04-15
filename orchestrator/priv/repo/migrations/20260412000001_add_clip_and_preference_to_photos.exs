defmodule Orchestrator.Repo.Migrations.AddClipAndPreferenceToPhotos do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"

    alter table(:photos) do
      add :clip_embedding, :vector, size: 768
      add :preference_score, :integer
      add :preference_model_version, :integer
    end

    create index(:photos, [:preference_score])
  end
end
