defmodule Orchestrator.Repo.Migrations.CreateErrorLogs do
  use Ecto.Migration

  def change do
    create table(:error_logs) do
      add :worker, :string, null: false
      add :file, :string
      add :reason, :text, null: false
      add :status, :integer
      add :attempt, :integer
      add :max_attempts, :integer
      add :detail, :map

      timestamps(updated_at: false)
    end

    create index(:error_logs, [:inserted_at])
    create index(:error_logs, [:worker])
  end
end
