defmodule Orchestrator.Repo.Migrations.AddContentTypeToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :content_type, :string
    end
  end
end
