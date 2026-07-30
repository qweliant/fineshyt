defmodule Orchestrator.Repo.Migrations.AddDupGroupToPhotos do
  use Ecto.Migration

  # Sibling field to `burst_group`. Holds a per-group integer for photos
  # whose filename collapses onto the same canonical stem after stripping
  # macOS-style copy suffixes (" copy", " copy 2", " (1)", …). Populated
  # by `mix fineshyt.detect_dup_copies` / `DupDetectionWorker`; surfaced
  # in the gallery's "Copies" tab next to "Bursts".
  def change do
    alter table(:photos) do
      add :dup_group, :integer
    end

    create index(:photos, [:dup_group])
  end
end
