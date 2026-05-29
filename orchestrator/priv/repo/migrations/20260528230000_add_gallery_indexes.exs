defmodule Orchestrator.Repo.Migrations.AddGalleryIndexes do
  use Ecto.Migration

  # The gallery filters every query by curation_status and sorts by
  # inserted_at (newest), user_rating, or preference_score. Without indexes
  # SQLite full-scans + temp-B-tree-sorts all rows per page + per count,
  # which is noticeably laggy at ~12k+ photos. (Postgres tolerated the scan;
  # SQLite needs the help.) preference_score + captured_at are already indexed.
  def change do
    # Hot path: base filter (curation_status) + default "newest" sort.
    create index(:photos, [:curation_status, :inserted_at])
    # rated/unrated filters and the rating_desc sort.
    create index(:photos, [:user_rating])
    # project-scoped views.
    create index(:photos, [:project])
  end
end
