defmodule Orchestrator.Repo.Migrations.AddCapturedAtToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :captured_at, :naive_datetime
    end

    create index(:photos, [:captured_at])
  end
end
