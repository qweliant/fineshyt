defmodule Orchestrator.Repo.Migrations.AddUserRatingToPhotos do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :user_rating, :integer, null: true
    end
  end
end
