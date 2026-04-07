defmodule Orchestrator.ErrorLog do
  @moduledoc """
  Persistent error log for worker failures, surfaced in real time on
  `OrchestratorWeb.LogsLive` (`/logs`).

  Storage:
    * Every `record/1` inserts a row into the `error_logs` table.
    * After insert, broadcasts on PubSub topic `"error_log"` so the LiveView
      page updates without polling.
    * `list/1` returns the most recent N rows for the LiveView mount.

  Schema fields are deliberately loose — `detail` is a JSONB map so the full
  structured payload from the Python AI worker (error_type, message,
  upstream.status_code, upstream.message, upstream.body, etc.) is preserved
  verbatim and can be pretty-printed in the UI.
  """

  use Ecto.Schema
  import Ecto.Query, only: [from: 2]
  alias Orchestrator.{ErrorLog, Repo}

  @topic "error_log"
  @default_limit 200

  schema "error_logs" do
    field :worker, :string
    field :file, :string
    field :reason, :string
    field :status, :integer
    field :attempt, :integer
    field :max_attempts, :integer
    field :detail, :map

    timestamps(updated_at: false)
  end

  # ── public API ────────────────────────────────────────────────────────────

  def topic, do: @topic

  @doc """
  Insert a new error entry and broadcast it. Accepts a plain map; missing
  fields are stored as nil. Returns the inserted struct or `:error` (failures
  here are swallowed so worker error reporting can never itself crash a job).
  """
  def record(attrs) when is_map(attrs) do
    do_record(build_params(attrs))
  rescue
    e ->
      require Logger
      Logger.warning("ErrorLog.record/1 raised: #{Exception.message(e)}")
      :error
  end

  defp build_params(attrs) do
    %{
      worker: to_string_or_nil(fetch(attrs, :worker)),
      file: to_string_or_nil(fetch(attrs, :file)),
      reason: to_string_or_nil(fetch(attrs, :reason)) || "(no reason)",
      status: fetch(attrs, :status),
      attempt: fetch(attrs, :attempt),
      max_attempts: fetch(attrs, :max) || fetch(attrs, :max_attempts),
      detail: normalize_detail(fetch(attrs, :detail))
    }
  end

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, to_string(key)))

  defp do_record(params) do
    %ErrorLog{}
    |> Ecto.Changeset.cast(params, [:worker, :file, :reason, :status, :attempt, :max_attempts, :detail])
    |> Ecto.Changeset.validate_required([:worker, :reason])
    |> Repo.insert()
    |> handle_insert()
  end

  defp handle_insert({:ok, entry}) do
    Phoenix.PubSub.broadcast(Orchestrator.PubSub, @topic, {:error_logged, entry})
    entry
  end

  defp handle_insert({:error, changeset}) do
    require Logger
    Logger.warning("ErrorLog.record/1 failed to insert: #{inspect(changeset.errors)}")
    :error
  end

  @doc "Return the most recent entries, newest first. Defaults to 200."
  def list(limit \\ @default_limit) when is_integer(limit) and limit > 0 do
    from(e in ErrorLog,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Return the total number of error rows in the table."
  def count do
    Repo.aggregate(ErrorLog, :count, :id)
  end

  @doc "Delete all rows and broadcast a clear event."
  def clear do
    Repo.delete_all(ErrorLog)
    Phoenix.PubSub.broadcast(Orchestrator.PubSub, @topic, :error_log_cleared)
    :ok
  end

  # ── private ───────────────────────────────────────────────────────────────

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v) when is_binary(v), do: v
  defp to_string_or_nil(v), do: to_string(v)

  # `detail` lands in a JSONB column, so it must be a map. Anything else
  # (string, list, atom, struct) gets wrapped so we never lose the data.
  defp normalize_detail(nil), do: nil
  defp normalize_detail(%_{} = struct), do: %{"value" => inspect(struct)}
  defp normalize_detail(map) when is_map(map), do: map
  defp normalize_detail(other), do: %{"value" => inspect(other)}
end
