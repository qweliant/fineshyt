defmodule Orchestrator.Repo.Migrations.AddStatusToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :curation_status, :string, default: "complete", null: false
    end

    # All existing rows are already processed
    execute "UPDATE photos SET curation_status = 'complete'", ""
  end
end
