defmodule Orchestrator.Repo.Migrations.TextColumnsForPhotoStrings do
  use Ecto.Migration

  # LLM outputs regularly exceed varchar(255). Promote all free-text fields to
  # unbounded :text so truncation errors never surface again.
  def change do
    alter table(:photos) do
      modify :subject,           :text
      modify :artistic_mood,     :text
      modify :lighting_critique, :text
      modify :style_reason,      :text
    end
  end
end
