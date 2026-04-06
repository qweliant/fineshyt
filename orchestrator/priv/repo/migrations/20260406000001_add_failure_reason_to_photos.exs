defmodule Orchestrator.Repo.Migrations.AddFailureReasonToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :failure_reason, :text
    end
  end
end
