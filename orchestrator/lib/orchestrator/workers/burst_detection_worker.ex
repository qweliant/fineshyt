defmodule Orchestrator.Workers.BurstDetectionWorker do
  @moduledoc """
  Oban worker that gathers CLIP embeddings for all curated photos, sends
  them to the Python worker's `/api/v1/detect_bursts` endpoint for cosine
  similarity clustering, and writes back `burst_group` assignments.

  ## Queue

  Runs on the `:preference` queue (concurrency 1) since it does a single
  large computation pass and shares the "batch analysis" nature of the
  preference train job. Uses `unique: [period: 60]` so double-clicks in
  the UI collapse.

  ## Flow

    1. `Photos.list_photos_for_burst_detection/0` — gather `{id, embedding,
       sharpness_score, captured_at}` for all complete, embedded photos.
    2. POST to `/api/v1/detect_bursts` with a configurable similarity
       threshold (default 0.95).
    3. Flatten the returned groups into `{photo_id, group_id}` assignments
       and write via `Photos.assign_burst_groups/1`.
    4. Broadcast `{:burst_detection_complete, n_groups}` on `"photo_updates"`
       so the gallery refreshes.
  """

  use Oban.Worker,
    queue: :preference,
    max_attempts: 2,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  require Logger

  alias Orchestrator.{ErrorLog, Photos}

  @worker_name "BurstDetectionWorker"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    threshold = Map.get(args, "similarity_threshold", 0.95)
    photos = Photos.list_photos_for_burst_detection()
    Logger.info("BurstDetectionWorker: #{length(photos)} photos with embeddings")

    if length(photos) < 2 do
      Logger.info("BurstDetectionWorker: <2 embedded photos, nothing to cluster")
      :ok
    else
      payload = %{
        similarity_threshold: threshold,
        max_time_gap_seconds: Map.get(args, "max_time_gap_seconds", 5.0),
        photos:
          Enum.map(photos, fn {id, vec, sharpness, captured_at} ->
            %{
              id: id,
              embedding: Pgvector.to_list(vec),
              sharpness_score: sharpness || 0,
              captured_at: if(captured_at, do: NaiveDateTime.to_iso8601(captured_at))
            }
          end)
      }

      case Req.post("http://127.0.0.1:8000/api/v1/detect_bursts",
             json: payload,
             receive_timeout: 120_000
           ) do
        {:ok, %Req.Response{status: 200, body: %{"groups" => groups}}} ->
          assignments =
            Enum.flat_map(groups, fn %{"group_id" => gid, "photo_ids" => ids} ->
              Enum.map(ids, fn id -> {id, gid} end)
            end)

          Photos.assign_burst_groups(assignments)

          Logger.info(
            "BurstDetectionWorker: #{length(groups)} burst groups, " <>
              "#{length(assignments)} photos in bursts"
          )

          Phoenix.PubSub.broadcast(
            Orchestrator.PubSub,
            "photo_updates",
            {:burst_detection_complete, length(groups)}
          )

          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          detail = get_in(body, ["detail"]) || "status #{status}"
          Logger.error("Burst detection API failed: #{inspect(detail)}")

          ErrorLog.record(%{
            worker: @worker_name,
            file: "detect_bursts",
            reason: "API #{status}: #{inspect(detail)}",
            status: status,
            detail: body,
            attempt: job.attempt,
            max: job.max_attempts
          })

          {:error, inspect(detail)}

        {:error, reason} ->
          Logger.error("Could not reach burst detection API: #{inspect(reason)}")

          ErrorLog.record(%{
            worker: @worker_name,
            file: "detect_bursts",
            reason: "Transport: #{inspect(reason)}",
            detail: %{transport: inspect(reason)},
            attempt: job.attempt,
            max: job.max_attempts
          })

          {:error, inspect(reason)}
      end
    end
  end
end
