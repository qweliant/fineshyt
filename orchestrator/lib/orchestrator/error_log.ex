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

  @doc """
  Return the PubSub topic name that `record/1` and `clear/0` broadcast on.

  LiveViews use this in their `mount/3` to subscribe — keeping the topic
  string centralized here means there is exactly one place to change it.

  ## Returns

    * `String.t()` — currently `"error_log"`.

  ## Examples

      iex> Orchestrator.ErrorLog.topic()
      "error_log"
  """
  def topic, do: @topic

  @doc """
  Insert a new error entry into the `error_logs` table and broadcast it on
  PubSub so any subscribed LiveView updates in real time.

  Failures inside this function are swallowed by design: a worker that is
  *already* failing must never crash a second time just because error
  reporting hit a transient DB hiccup. Both insert errors and unexpected
  exceptions log a warning and return `:error`.

  ## Parameters

    * `attrs` — a map (atom or string keys are both accepted) with any of:
      * `:worker` — short identifier, e.g. `"AiCurationWorker"`
      * `:file` — file path or basename the failure relates to
      * `:reason` — short human reason; defaults to `"(no reason)"` if missing
      * `:status` — HTTP-style status integer when applicable
      * `:attempt`, `:max` (or `:max_attempts`) — Oban retry counters
      * `:detail` — arbitrary map (lands in a JSONB column); non-map values
        are wrapped via `inspect/1` so the data is never lost.

  ## Returns

    * `%Orchestrator.ErrorLog{}` — the inserted row, on success.
    * `:error` — on insert failure or rescued exception (warning logged).

  ## Examples

      Orchestrator.ErrorLog.record(%{
        worker: "AiCurationWorker",
        file: "DSC_0001.jpg",
        reason: "Python API failed",
        status: 500,
        attempt: 3,
        max: 3,
        detail: %{"error_type" => "APIConnectionError"}
      })
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

  @doc """
  Fetch the most recent error entries, newest first.

  Used by `OrchestratorWeb.LogsLive` on mount to backfill the page before
  PubSub takes over for live updates.

  ## Parameters

    * `limit` — maximum number of rows to return. Defaults to `200`.

  ## Returns

    * `[%Orchestrator.ErrorLog{}]` — list of rows, newest first, ordered by
      `inserted_at` then `id` descending. Empty list if the table is empty.

  ## Examples

      Orchestrator.ErrorLog.list()      # latest 200
      Orchestrator.ErrorLog.list(500)   # latest 500
  """
  def list(limit \\ @default_limit) when is_integer(limit) and limit > 0 do
    from(e in ErrorLog,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Return the total number of error rows currently in the table.

  Cheap aggregate query — used by the LogsLive header to show a running
  total alongside the visible page.

  ## Returns

    * `non_neg_integer()` — total count of rows in `error_logs`.

  ## Examples

      iex> Orchestrator.ErrorLog.count()
      0
  """
  def count do
    Repo.aggregate(ErrorLog, :count, :id)
  end

  @doc """
  Delete every row from the `error_logs` table and broadcast a clear event
  so any subscribed LiveView wipes its in-memory list.

  Destructive — there is no soft-delete here. Intended for the dev "Clear"
  button on `/logs`.

  ## Returns

    * `:ok` — always.

  ## Examples

      Orchestrator.ErrorLog.clear()
  """
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
