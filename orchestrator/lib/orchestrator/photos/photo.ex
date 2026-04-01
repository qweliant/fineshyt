defmodule Orchestrator.Photos.Photo do
  use Ecto.Schema
  import Ecto.Changeset

  schema "photos" do
    field :file_path, :string
    field :url, :string
    field :source, :string
    field :instagram_shortcode, :string

    field :style_match, :boolean
    field :style_score, :integer
    field :style_reason, :string

    field :subject, :string
    field :artistic_mood, :string
    field :lighting_critique, :string
    field :is_macro, :boolean
    field :suggested_tags, {:array, :string}, default: []

    timestamps()
  end

  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [
      :file_path, :url, :source, :instagram_shortcode,
      :style_match, :style_score, :style_reason,
      :subject, :artistic_mood, :lighting_critique, :is_macro, :suggested_tags
    ])
    |> validate_required([:file_path])
    |> unique_constraint(:instagram_shortcode)
  end
end
