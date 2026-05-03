defmodule Orchestrator.Repo.Migrations.AddSidecarFieldsToPhotos do
  use Ecto.Migration

  @moduledoc """
  Adds the two columns that let Fine.Shyt round-trip metadata to/from
  XMP sidecars next to the user's original RAW/source files.

    * `source_path`         — absolute path of the original source file
                              the converted JPEG came from. Sidecar
                              location is derived as `<source_path>.xmp`
                              or `<basename(source_path, .ext)>.xmp`.
    * `sidecar_synced_at`   — last UTC time we wrote the sidecar; used
                              to skip-if-newer when the user's editor
                              has touched it since.

  Both nullable because pre-Fine.Shyt-v(sidecars) photos won't have
  this metadata.
  """

  def change do
    alter table(:photos) do
      add :source_path, :string
      add :sidecar_synced_at, :naive_datetime
    end
  end
end
