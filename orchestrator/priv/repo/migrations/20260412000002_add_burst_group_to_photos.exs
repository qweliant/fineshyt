defmodule Orchestrator.Repo.Migrations.AddBurstGroupToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :burst_group, :integer
    end

    create index(:photos, [:burst_group])
  end
end
