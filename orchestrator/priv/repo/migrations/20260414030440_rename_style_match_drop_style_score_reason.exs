defmodule Orchestrator.Repo.Migrations.RenameStyleMatchDropStyleScoreReason do
  use Ecto.Migration

  def change do
    rename table(:photos), :style_match, to: :manual_match

    alter table(:photos) do
      remove :style_score, :integer
      remove :style_reason, :text
    end
  end
end
