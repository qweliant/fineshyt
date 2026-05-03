defmodule Orchestrator.Photos.Photo do
  @moduledoc """
  Ecto schema for a single photo flowing through the curation pipeline.

  ## Field groups

    * **Source / location**
      * `file_path` — absolute path on disk (required)
      * `url` — web-servable path under `/uploads/...`
      * `source` — `"local"`

    * **Manual override**
      * `manual_match` — boolean: user-flagged "chef's pick." Independent
        of the preference model; used to override or augment the
        automatic MATCH badge in the gallery.

    * **Technical quality** (computed by the Python converter on the full-res image)
      * `technical_score` — 0–100 weighted blend (0.7 sharpness + 0.3 exposure)
      * `sharpness_score` — variance-of-Laplacian, normalized 0–100
      * `exposure_score` — histogram clipping penalty, 0–100

    * **Preference learning** (CLIP embedding + Ridge linear probe)
      * `clip_embedding` — 768-dim CLIP image embedding (`ViT-L-14`),
        populated by `Orchestrator.Workers.EmbeddingWorker`
      * `preference_score` — 0–100 personalized score from the Ridge model
        fit on the user's star ratings
      * `preference_model_version` — integer version of the Ridge model that
        produced the current `preference_score`; stale rows are re-scored
        on the next retrain

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

    field :manual_match, :boolean, default: false

    field :technical_score, :integer
    field :sharpness_score, :integer
    field :exposure_score, :integer

    field :clip_embedding, Pgvector.Ecto.Vector
    field :preference_score, :integer
    field :preference_model_version, :integer

    field :subject, :string
    field :artistic_mood, :string
    field :lighting_critique, :string
    field :content_type, :string
    field :suggested_tags, {:array, :string}, default: []
    field :user_rating, :integer
    field :project, :string
    field :captured_at, :naive_datetime
    field :burst_group, :integer
    field :curation_status, :string, default: "complete"
    field :failure_reason, :string

    # XMP sidecar tracking. `source_path` is the original RAW/source file
    # the JPEG was converted from — XMP sidecars sit next to it as
    # `<source>.xmp`. `sidecar_synced_at` records the last time
    # Fine.Shyt wrote the sidecar so we can skip-if-newer when the user's
    # editor has touched it since.
    field :source_path, :string
    field :sidecar_synced_at, :naive_datetime

    timestamps()
  end

  @doc """
  Build a changeset for inserts and updates.

  Casts every user-and-AI-writable field, validates that `user_rating` (when
  present) sits in 1..5, and requires `file_path`.

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
      :file_path, :url, :source,
      :manual_match,
      :technical_score, :sharpness_score, :exposure_score,
      :clip_embedding, :preference_score, :preference_model_version,
      :subject, :artistic_mood, :lighting_critique, :content_type, :suggested_tags,
      :user_rating, :project, :captured_at, :burst_group, :curation_status, :failure_reason,
      :source_path, :sidecar_synced_at
    ])
    |> validate_inclusion(:user_rating, 1..5, message: "must be between 1 and 5")
    |> validate_required([:file_path])
  end
end
