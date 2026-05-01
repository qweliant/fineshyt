defmodule Orchestrator.Workers.PreferenceTrainWorker do
  @moduledoc """
  Oban worker that retrains the personalized preference model on the user's
  rating history, then backfills `preference_score` for every photo that has
  a CLIP embedding.

  ## Queue, concurrency, debouncing

  Runs on the `:preference` queue with concurrency 1 — there is exactly one
  pickled model on disk and no benefit to racing retrains. Uses
  `unique: [period: 300, fields: [:worker, :queue],
  states: [:available, :scheduled, :executing, :completed]]` so that any
  retrain attempt within 5 minutes of the last one — regardless of
  `trigger` args — is suppressed. `:completed` is included so a finished
  retrain enforces a real cooldown instead of the next enqueue firing
  immediately.

  ## Flow

    1. Gather `{id, embedding, rating}` for every "complete" photo that has
       both a star rating and a CLIP embedding.
    2. Bail cleanly (log + `:ok`) if fewer than 20 labeled samples exist —
       Ridge on tiny label counts is noise.
    3. POST the samples to `http://127.0.0.1:8000/api/v1/preference/train`.
       The Python worker pickles the fitted Ridge + scaler to disk and
       returns a new integer `model_version`.
    4. Page through `Photos.list_photos_needing_preference_score/2` in
       500-row batches, POST embeddings to `/api/v1/preference/score`, and
       batch-update `preference_score` + `preference_model_version` via
       `Photos.update_preference_scores/1`.
    5. Broadcast `{:preference_scores_updated, model_version}` on the
       `"photo_updates"` topic so LiveViews reload.

  Errors at any step are logged, recorded to `Orchestrator.ErrorLog`, and
  returned as `{:error, reason}` for Oban retry.
  """

  use Oban.Worker,
    queue: :preference,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker, :queue],
      states: [:available, :scheduled, :executing, :completed]
    ]

  require Logger

  alias Orchestrator.{ErrorLog, Photos}

  @worker_name "PreferenceTrainWorker"
  @min_samples 20
  @score_batch_size 500

  @doc """
  Oban entry point. Retrain the preference model and refresh scores.

  ## Parameters

    * `job` — `%Oban.Job{}`. `job.args` may carry `"trigger"` (free-form
      string, e.g. `"rating_change"`, `"embedding_added"`, `"manual"`) for
      debugging.

  ## Returns

    * `:ok` — training succeeded or was skipped (too few labels).
    * `{:error, reason}` — surfaced to Oban for retry.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    trigger = Map.get(args, "trigger", "manual")
    samples = Photos.list_rated_with_embeddings()

    if length(samples) < @min_samples do
      Logger.info("PreferenceTrainWorker: skipping (#{length(samples)} < #{@min_samples} samples, trigger=#{trigger})")
      :ok
    else
      Logger.info("PreferenceTrainWorker: training on #{length(samples)} samples (trigger=#{trigger})")

      payload = %{
        min_samples: @min_samples,
        samples:
          Enum.map(samples, fn {_id, vec, rating} ->
            %{embedding: Pgvector.to_list(vec), rating: rating}
          end)
      }

      case Req.post(Orchestrator.AiWorker.url("/api/v1/preference/train"),
             json: payload,
             receive_timeout: 120_000
           ) do
        {:ok, %Req.Response{status: 200, body: %{"model_version" => version} = body}} ->
          Logger.info(
            "Preference model trained: version=#{version} n=#{body["n_samples"]} r2=#{body["train_r2"]}"
          )

          case backfill_scores(version) do
            :ok ->
              Phoenix.PubSub.broadcast(
                Orchestrator.PubSub,
                "photo_updates",
                {:preference_scores_updated, version}
              )
              :ok

            {:error, reason} ->
              record_error(job, "backfill", reason, detail: %{version: version})
              {:error, reason}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          detail = get_in(body, ["detail"]) || "status #{status}"
          Logger.error("Preference train API failed: #{inspect(detail)}")
          record_error(job, "train", "API #{status}: #{inspect(detail)}", status: status, detail: body)
          {:error, inspect(detail)}

        {:error, reason} ->
          Logger.error("Could not reach preference train API: #{inspect(reason)}")
          record_error(job, "train", "Transport: #{inspect(reason)}", detail: %{transport: inspect(reason)})
          {:error, inspect(reason)}
      end
    end
  end

  defp backfill_scores(version) do
    case Photos.list_photos_needing_preference_score(version, @score_batch_size) do
      [] ->
        :ok

      rows ->
        embeddings = Enum.map(rows, fn {_id, vec} -> Pgvector.to_list(vec) end)

        case Req.post(Orchestrator.AiWorker.url("/api/v1/preference/score"),
               json: %{embeddings: embeddings},
               receive_timeout: 60_000
             ) do
          {:ok, %Req.Response{status: 200, body: %{"scores" => scores, "model_version" => v}}} ->
            updates =
              rows
              |> Enum.zip(scores)
              |> Enum.map(fn {{id, _vec}, score} -> {id, score, v} end)

            Photos.update_preference_scores(updates)
            # Recurse until the query returns no stale rows.
            backfill_scores(version)

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, "score API #{status}: #{inspect(body)}"}

          {:error, reason} ->
            {:error, "score transport: #{inspect(reason)}"}
        end
    end
  end

  defp record_error(%Oban.Job{attempt: attempt, max_attempts: max}, step, reason, opts) do
    ErrorLog.record(%{
      worker: @worker_name,
      file: step,
      reason: reason,
      status: Keyword.get(opts, :status),
      detail: Keyword.get(opts, :detail),
      attempt: attempt,
      max: max
    })
  end
end
