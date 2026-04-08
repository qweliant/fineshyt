defmodule Orchestrator.Photos.Photo do
  @moduledoc """
  Ecto schema for a single photo flowing through the curation pipeline.

  ## Field groups

    * **Source / location**
      * `file_path` — absolute path on disk (required)
      * `url` — web-servable path under `/uploads/...`
      * `source` — `"local"` or `"instagram"`
      * `instagram_shortcode` — unique IG shortcode when applicable

    * **Style verdict** (set by the AI worker)
      * `style_match` — boolean: does this photo match the photographer's style?
      * `style_score` — 0–100 confidence integer
      * `style_reason` — free-form explanation

    * **Content metadata** (set by the AI worker)
      * `subject`, `artistic_mood`, `lighting_critique`, `content_type`
      * `suggested_tags` — list of strings (defaults to `[]`)

    * **User decisions**
      * `user_rating` — 1..5 star rating (validated)
      * `project` — assigned project name, free text

    * **Lifecycle**
      * `curation_status` — state machine: `"pending"` → `"complete"` |
        `"failed"` | `"rejected"`. Defaults to `"complete"` for legacy rows.
      * `failure_reason` — populated when `curation_status = "failed"`

  ## Soft-delete vs hard-delete

  A photo with `curation_status = "rejected"` is **soft-deleted**: the file
  on disk is preserved and the row is excluded from default listings.
  `Orchestrator.Photos.restore_photo/1` can revert it.
  `Orchestrator.Photos.delete_photo/1` and `empty_trash/1` perform a
  **hard delete** that removes the file from disk and tombstones the row.
  """

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
    field :content_type, :string
    field :suggested_tags, {:array, :string}, default: []
    field :user_rating, :integer
    field :project, :string
    field :curation_status, :string, default: "complete"
    field :failure_reason, :string

    timestamps()
  end

  @doc """
  Build a changeset for inserts and updates.

  Casts every user-and-AI-writable field, validates that `user_rating` (when
  present) sits in 1..5, requires `file_path`, and enforces uniqueness on
  `instagram_shortcode` so re-ingesting the same IG post is a no-op.

  ## Parameters

    * `photo` — the existing `%Photo{}` (or `%Photo{}` for inserts)
    * `attrs` — map of attributes to cast

  ## Returns

    * `%Ecto.Changeset{}` — valid or invalid; check `changeset.valid?`.

  ## Examples

      %Orchestrator.Photos.Photo{}
      |> Orchestrator.Photos.Photo.changeset(%{file_path: "/uploads/a.jpg"})
      |> Orchestrator.Repo.insert()
  """
  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [
      :file_path, :url, :source, :instagram_shortcode,
      :style_match, :style_score, :style_reason,
      :subject, :artistic_mood, :lighting_critique, :content_type, :suggested_tags,
      :user_rating, :project, :curation_status, :failure_reason
    ])
    |> validate_inclusion(:user_rating, 1..5, message: "must be between 1 and 5")
    |> validate_required([:file_path])
    |> unique_constraint(:instagram_shortcode)
  end
end
