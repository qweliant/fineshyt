defmodule Orchestrator.Workers.EmbeddingWorker do
  @moduledoc """
  Oban worker that asks the Python AI service for a CLIP image embedding
  for a single already-curated photo, writes the vector onto the photos
  row, and triggers a debounced retrain of the preference model.

  ## Queue and concurrency

  Runs on the `:embedding` queue (concurrency 2 in `config.exs`). CLIP on
  CPU is compute-bound; a small fan-out keeps the CPU busy without
  thrashing against the LLM worker sharing the machine.

  ## Flow

    1. Load the photo by id and bail if the file is gone.
    2. POST `{file_path}` to `http://127.0.0.1:8000/api/v1/embed` with a
       120s timeout (first call pays the ~900MB CLIP model load).
    3. On HTTP 200, persist `clip_embedding` via `Photos.override_curation/2`.
    4. Enqueue follow-up preference work. A retrain only makes sense
       when this photo contributes a new training sample, i.e. it has a
       `user_rating` already. Otherwise the new embedding just needs its
       `preference_score` computed against the existing model, so we
       enqueue a `PreferenceScoreWorker` instead. This keeps batch
       imports of unrated photos from triggering hundreds of pointless
       retrains.
    5. On any non-200, transport error, or exception: detail is logged,
       recorded to `Orchestrator.ErrorLog`, and `{:error, reason}` is
       returned so Oban retries up to `max_attempts: 3`.
  """

  use Oban.Worker,
    queue: :embedding,
    max_attempts: 3

  require Logger

  alias Orchestrator.{ErrorLog, Photos}

  @worker_name "EmbeddingWorker"

  @doc """
  Oban entry point. Fetch the CLIP embedding for a single photo and write
  it back.

  ## Parameters

    * `job` — `%Oban.Job{}`. `job.args` must include `"photo_id"`.

  ## Returns

    * `:ok` — embedding computed and persisted.
    * `{:error, reason}` — surfaced to Oban for retry handling.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"photo_id" => photo_id}} = job) do
    photo = Photos.get_photo!(photo_id)
    basename = Path.basename(photo.file_path)

    cond do
      not File.exists?(photo.file_path) ->
        Logger.warning("EmbeddingWorker: file missing for photo #{photo_id} (#{photo.file_path})")
        record_error(job, basename, "file missing: #{photo.file_path}", detail: %{photo_id: photo_id})
        {:error, "file missing"}

      not is_nil(photo.clip_embedding) ->
        Logger.debug("EmbeddingWorker: photo #{photo_id} already embedded, skipping")
        :ok

      true ->
        Logger.info("Embedding photo #{photo_id} (#{basename})...")

        case Req.post("http://127.0.0.1:8000/api/v1/embed",
               json: %{file_path: photo.file_path},
               receive_timeout: 120_000
             ) do
          {:ok, %Req.Response{status: 200, body: %{"embedding" => embedding}}} ->
            case Photos.override_curation(photo_id, %{clip_embedding: embedding}) do
              {:ok, _photo} ->
                enqueue_preference_followup(photo)

                Logger.info("Embedded photo #{photo_id} (dim=#{length(embedding)})")
                :ok

              {:error, changeset} ->
                Logger.error("EmbeddingWorker: failed to persist embedding: #{inspect(changeset.errors)}")
                record_error(job, basename, "persist failed", detail: %{errors: inspect(changeset.errors)})
                {:error, "persist failed"}
            end

          {:ok, %Req.Response{status: status, body: body}} ->
            detail = get_in(body, ["detail"]) || "status #{status}"
            Logger.error("Embed API failed for photo #{photo_id}: #{inspect(detail)}")
            record_error(job, basename, "API #{status}: #{inspect(detail)}", status: status, detail: body)
            {:error, inspect(detail)}

          {:error, reason} ->
            Logger.error("Could not reach embed API: #{inspect(reason)}")
            record_error(job, basename, "Transport: #{inspect(reason)}", detail: %{transport: inspect(reason)})
            {:error, inspect(reason)}
        end
    end
  end

  defp enqueue_preference_followup(%{user_rating: rating, id: id}) when not is_nil(rating) do
    Orchestrator.Workers.PreferenceTrainWorker.new(%{trigger: "rated_embedding_added", photo_id: id})
    |> Oban.insert()
  end

  defp enqueue_preference_followup(%{id: id}) do
    Orchestrator.Workers.PreferenceScoreWorker.new(%{photo_id: id})
    |> Oban.insert()
  end

  defp record_error(%Oban.Job{attempt: attempt, max_attempts: max}, basename, reason, opts) do
    ErrorLog.record(%{
      worker: @worker_name,
      file: basename,
      reason: reason,
      status: Keyword.get(opts, :status),
      detail: Keyword.get(opts, :detail),
      attempt: attempt,
      max: max
    })
  end
end
