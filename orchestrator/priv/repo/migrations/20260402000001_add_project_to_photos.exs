defmodule Orchestrator.Repo.Migrations.AddProjectToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :project, :string
    end
  end
end
