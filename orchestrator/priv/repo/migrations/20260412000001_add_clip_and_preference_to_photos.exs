defmodule Orchestrator.Repo.Migrations.AddClipAndPreferenceToPhotos do
  use Ecto.Migration

  def change do
    # clip_embedding is a packed float32 blob (see Orchestrator.Embedding).
    # No in-DB vector search happens — embeddings are loaded into Elixir and
    # sent to the Python ai_worker for all distance math — so a plain BLOB
    # column suffices and SQLite needs no vector extension.
    alter table(:photos) do
      add :clip_embedding, :binary
      add :preference_score, :integer
      add :preference_model_version, :integer
    end

    create index(:photos, [:preference_score])
  end
end
