defmodule Orchestrator.Workers.PreferenceScoreWorker do
  @moduledoc """
  Oban worker that scores a single photo against the already-trained
  preference model.

  Splits the "score-only" path off from `PreferenceTrainWorker` so that a
  freshly-embedded *unrated* photo can get its `preference_score` without
  refitting the Ridge model. Training data = `{rated photo, embedding}`
  pairs, so a new embedding on an unrated photo adds nothing to the
  training set — only a score backfill is needed.

  Runs on the `:preference` queue (concurrency 1, shared with
  `PreferenceTrainWorker`). Sub-100ms: one HTTP call, one row update.

  If no preference model has been trained yet, the Python side returns
  400; this worker logs and returns `:ok` so Oban doesn't retry.
  """

  use Oban.Worker,
    queue: :preference,
    max_attempts: 3

  require Logger

  alias Orchestrator.{ErrorLog, Photos}

  @worker_name "PreferenceScoreWorker"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"photo_id" => photo_id}} = job) do
    photo = Photos.get_photo!(photo_id)

    cond do
      is_nil(photo.clip_embedding) ->
        Logger.debug("PreferenceScoreWorker: photo #{photo_id} has no embedding, skipping")
        :ok

      true ->
        embedding = Pgvector.to_list(photo.clip_embedding)

        case Req.post("http://127.0.0.1:8000/api/v1/preference/score",
               json: %{embeddings: [embedding]},
               receive_timeout: 30_000
             ) do
          {:ok, %Req.Response{status: 200, body: %{"scores" => [score], "model_version" => version}}} ->
            Photos.update_preference_scores([{photo_id, score, version}])

            Phoenix.PubSub.broadcast(
              Orchestrator.PubSub,
              "photo_updates",
              {:preference_scores_updated, version}
            )

            :ok

          {:ok, %Req.Response{status: 400}} ->
            Logger.debug("PreferenceScoreWorker: no model trained yet, skipping photo #{photo_id}")
            :ok

          {:ok, %Req.Response{status: status, body: body}} ->
            detail = get_in(body, ["detail"]) || "status #{status}"
            record_error(job, photo_id, "API #{status}: #{inspect(detail)}", status: status, detail: body)
            {:error, inspect(detail)}

          {:error, reason} ->
            record_error(job, photo_id, "Transport: #{inspect(reason)}", detail: %{transport: inspect(reason)})
            {:error, inspect(reason)}
        end
    end
  end

  defp record_error(%Oban.Job{attempt: attempt, max_attempts: max}, photo_id, reason, opts) do
    ErrorLog.record(%{
      worker: @worker_name,
      file: "photo_#{photo_id}",
      reason: reason,
      status: Keyword.get(opts, :status),
      detail: Keyword.get(opts, :detail),
      attempt: attempt,
      max: max
    })
  end
end
