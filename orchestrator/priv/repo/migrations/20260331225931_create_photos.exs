defmodule Orchestrator.Repo.Migrations.CreatePhotos do
  use Ecto.Migration

  def change do
    create table(:photos) do
      add :file_path, :string, null: false
      add :url, :string
      add :source, :string
      add :instagram_shortcode, :string

      add :style_match, :boolean
      add :style_score, :integer
      add :style_reason, :string

      add :subject, :string
      add :artistic_mood, :string
      add :lighting_critique, :string
      add :is_macro, :boolean
      add :suggested_tags, {:array, :string}, default: []

      timestamps()
    end

    create unique_index(:photos, [:instagram_shortcode],
             where: "instagram_shortcode IS NOT NULL"
           )
  end
end
