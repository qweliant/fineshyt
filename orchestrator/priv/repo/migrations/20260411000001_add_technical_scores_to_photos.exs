defmodule Orchestrator.Repo.Migrations.AddTechnicalScoresToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :technical_score, :integer
      add :sharpness_score, :integer
      add :exposure_score, :integer
    end
  end
end
