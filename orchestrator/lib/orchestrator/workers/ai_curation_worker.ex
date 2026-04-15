defmodule Orchestrator.Workers.AiCurationWorker do
  @moduledoc """
  Oban worker that hands a single image to the Python AI service for
  curation, persists the resulting metadata, and broadcasts the outcome.

  ## Queue and concurrency

  Runs on the `:ai_jobs` queue with `max_attempts: 3`. The queue is
  configured with concurrency 1 in `config.exs` so only one image is in
  flight at a time — the local Ollama instance has limited RAM and parallel
  curation requests would thrash. The companion `ConversionWorker` runs in
  parallel since RAW conversion is purely CPU.

  ## Flow

    1. Copy the source file into `priv/static/uploads/` (skipped when the
       source already lives there).
    2. Short-circuit if `Orchestrator.Photos.already_processed?/1` says
       this file is already complete or rejected.
    3. POST the image to `http://127.0.0.1:8000/api/v1/curate` with a
       generous 5-minute receive timeout (LLaVA on M3 with tight RAM
       routinely exceeds 60s).
    4. On HTTP 200, persist the photo via `Photos.create_photo/1` and
       broadcast `{:curation_complete, ref, metadata, basename}` on
       `"photo_updates"`.
    5. On any non-200, transport error, or unexpected exception: structured
       detail is parsed via `format_api_error/1`, recorded to
       `Orchestrator.ErrorLog`, and surfaced via `{:curation_failed, ...}`.
       After Oban exhausts all attempts, `Photos.create_failed/1` writes a
       persistent failure tombstone the gallery can show.

  ## Job args

    * `"file_path"` (required) — absolute path to source file
    * `"ref"` (required) — opaque reference echoed back in PubSub messages
    * `"source"` (optional, default `"upload"`)
    * `"project"` (optional)

  ## Return values (visible to Oban)

    * `:ok` — success or skipped
    * `{:error, reason}` — surfaced to Oban so it can retry
  """

  use Oban.Worker,
    queue: :ai_jobs,
    max_attempts: 3

  require Logger

  alias Orchestrator.{ErrorLog, Photos}

  @worker_name "AiCurationWorker"

  @doc """
  Oban entry point. Curate a single image and persist its metadata.

  See the module doc for full flow. This function is the only public API
  on the worker — Oban dispatches all jobs through it.

  ## Parameters

    * `job` — `%Oban.Job{}`. `job.args` must include `"file_path"` and
      `"ref"`; see module doc for the optional fields.

  ## Returns

    * `:ok` — curation succeeded *or* the file was already processed.
    * `{:error, reason}` — surfaced to Oban for retry handling. After the
      final attempt the worker also writes a failed-photo row and emits
      `{:curation_failed, ref, basename, reason}` on the `"photo_updates"`
      PubSub topic.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"file_path" => file_path, "ref" => ref} = args
      } = job) do
    Logger.info("Starting AI curation for #{file_path}...")

    source = Map.get(args, "source", "upload")
    project = Map.get(args, "project")
    technical_score = Map.get(args, "technical_score")
    sharpness_score = Map.get(args, "sharpness_score")
    exposure_score = Map.get(args, "exposure_score")
    captured_at = parse_captured_at(Map.get(args, "captured_at"))
    basename = Path.basename(file_path)

    uploads_dir = Path.join([:code.priv_dir(:orchestrator), "static", "uploads"])
    dest = Path.join(uploads_dir, basename)

    result =
      try do
        File.mkdir_p!(uploads_dir)
        if file_path != dest, do: File.cp!(file_path, dest)

        if Photos.already_processed?(dest) do
          Logger.info("Skipping #{basename} — already processed.")
          Phoenix.PubSub.broadcast(
            Orchestrator.PubSub,
            "photo_updates",
            {:curation_skipped, ref, basename}
          )
          :ok
        else
          image_binary = File.read!(dest)

          form_fields = [file: {image_binary, filename: basename, content_type: "image/jpeg"}]

          case Req.post("http://127.0.0.1:8000/api/v1/curate",
                 form_multipart: form_fields,
                 receive_timeout: 300_000
               ) do
            {:ok, %Req.Response{status: 200, body: metadata}} ->
              Photos.delete_failed_if_exists(dest)

              insert_result =
                Photos.create_photo(%{
                  file_path: dest,
                  url: "/uploads/#{basename}",
                  source: source,
                  project: project,
                  technical_score: technical_score,
                  sharpness_score: sharpness_score,
                  exposure_score: exposure_score,
                  subject: metadata["subject"],
                  artistic_mood: metadata["artistic_mood"],
                  lighting_critique: metadata["lighting_critique"],
                  content_type: metadata["content_type"],
                  suggested_tags: metadata["suggested_tags"],
                  captured_at: captured_at,
                  curation_status: "complete"
                })

              # Kick off CLIP embedding in the background. Embedding failures
              # are non-fatal for curation — the photo is already usable.
              case insert_result do
                {:ok, %{id: photo_id}} ->
                  Orchestrator.Workers.EmbeddingWorker.new(%{photo_id: photo_id})
                  |> Oban.insert()

                _ ->
                  :noop
              end

              Logger.info("AI Curation successful for #{basename}!")
              Phoenix.PubSub.broadcast(
                Orchestrator.PubSub,
                "photo_updates",
                {:curation_complete, ref, metadata, basename}
              )
              :ok

            {:ok, %Req.Response{status: status, body: body}} ->
              detail = format_api_error(body)
              Logger.error(
                "Python API failed for #{basename} with status #{status}: #{detail}"
              )
              record_error(job, basename, "API #{status}: #{detail}", status: status, detail: body)
              {:error, "API #{status}: #{detail}"}

            {:error, reason} ->
              Logger.error(
                "Failed to reach AI service for #{basename}: #{inspect(reason)}"
              )
              record_error(job, basename, "Transport: #{inspect(reason)}", detail: %{transport: inspect(reason)})
              {:error, inspect(reason)}
          end
        end
      rescue
        e ->
          msg = Exception.message(e)
          Logger.error("AI curation raised an exception: #{msg}")
          record_error(job, basename, "Exception: #{msg}", detail: %{exception: inspect(e), stacktrace: Exception.format_stacktrace(__STACKTRACE__)})
          {:error, msg}
      end

    if result != :ok, do: maybe_broadcast_failure(ref, job, dest, basename, source, project, result)
    result
  end

  # Pulls the most useful piece out of the structured `detail` payload that
  # ai_worker/src/main.py now returns. Falls back to inspect/2 for anything
  # unexpected so we never lose information.
  defp format_api_error(%{"detail" => detail}), do: format_api_error(detail)

  defp format_api_error(%{"error_type" => type, "message" => msg} = payload) do
    upstream =
      case payload do
        %{"upstream" => %{"status_code" => sc, "message" => um}} when not is_nil(sc) ->
          " (upstream #{sc}: #{um})"

        %{"upstream" => %{"message" => um}} when is_binary(um) ->
          " (upstream: #{um})"

        _ ->
          ""
      end

    "#{type}: #{msg}#{upstream}"
  end

  defp format_api_error(detail) when is_binary(detail), do: detail
  defp format_api_error(other), do: inspect(other)

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

  defp maybe_broadcast_failure(ref, %Oban.Job{attempt: attempt, max_attempts: max}, dest, basename, source, project, result) do
    reason = case result do
      {:error, r} -> r
      _ -> "unknown error"
    end

    if attempt >= max do
      Logger.info("All attempts exhausted for #{basename}, persisting failure.")
      Photos.create_failed(%{
        file_path: dest,
        url: "/uploads/#{basename}",
        source: source,
        project: project,
        failure_reason: reason
      })
    end

    Phoenix.PubSub.broadcast(
      Orchestrator.PubSub,
      "photo_updates",
      {:curation_failed, ref, basename, reason}
    )
  end

  defp parse_captured_at(nil), do: nil
  defp parse_captured_at(str) when is_binary(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> ndt
      _ -> nil
    end
  end
  defp parse_captured_at(_), do: nil
end
