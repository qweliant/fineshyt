defmodule Orchestrator.Workers.ConversionWorker do
  @moduledoc """
  Oban worker that hands a single source file (RAW or otherwise) to the
  Python AI service for conversion to a resized JPEG, then enqueues an
  `AiCurationWorker` job for the result.

  ## Queue and concurrency

  Runs on the `:conversion` queue, which allows parallel execution since
  RAW conversion is purely CPU-bound and stateless. Curation is the
  bottleneck and is intentionally serialized in `AiCurationWorker`.

  ## Flow

    1. POST `{file_path}` to `http://127.0.0.1:8000/api/v1/convert` with a
       60s timeout (rawpy on a large RAW file can take that long).
    2. On HTTP 200, enqueue an `AiCurationWorker` job pointing at the
       returned `jpeg_path`, carrying through `ref`, `style_description`,
       `source`, and `project`.
    3. On any non-200, transport error, or exception: detail is logged,
       recorded to `Orchestrator.ErrorLog`, and `{:error, reason}` is
       returned so Oban will retry up to `max_attempts: 3`.
  """

  use Oban.Worker,
    queue: :conversion,
    max_attempts: 3

  require Logger

  alias Orchestrator.ErrorLog

  @worker_name "ConversionWorker"

  @doc """
  Oban entry point. Convert a single source file to JPEG and enqueue
  curation.

  See the module doc for the full flow.

  ## Parameters

    * `job` — `%Oban.Job{}`. `job.args` must include `"file_path"`.
      Optional keys: `"ref"`, `"style_description"`, `"source"`, `"project"`.

  ## Returns

    * `:ok` — conversion succeeded and the curation job has been enqueued.
    * `{:error, reason}` — surfaced to Oban for retry handling.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_path" => file_path} = args} = job) do
    ref = Map.get(args, "ref", inspect(make_ref()))
    style_description = Map.get(args, "style_description", "")
    source = Map.get(args, "source", "local")
    project = Map.get(args, "project")

    Logger.info("Converting #{Path.basename(file_path)}...")

    case Req.post("http://127.0.0.1:8000/api/v1/convert",
           json: %{file_path: file_path},
           # rawpy on a large RAW file can take up to 60s
           receive_timeout: 60_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"jpeg_path" => jpeg_path} = body}} ->
        Logger.info("Converted #{Path.basename(file_path)} → #{Path.basename(jpeg_path)}")

        %{
          "file_path" => jpeg_path,
          "ref" => ref,
          "style_description" => style_description,
          "source" => source,
          "project" => project,
          "technical_score" => body["technical_score"],
          "sharpness_score" => body["sharpness_score"],
          "exposure_score" => body["exposure_score"],
          "captured_at" => body["captured_at"]
        }
        |> Orchestrator.Workers.AiCurationWorker.new()
        |> Oban.insert()

        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        detail = get_in(body, ["detail"]) || "status #{status}"
        Logger.error("Conversion failed for #{Path.basename(file_path)}: #{inspect(detail)}")

        record_error(job, Path.basename(file_path), "API #{status}: #{inspect(detail)}",
          status: status,
          detail: body
        )

        {:error, inspect(detail)}

      {:error, reason} ->
        Logger.error("Could not reach convert API: #{inspect(reason)}")

        record_error(job, Path.basename(file_path), "Transport: #{inspect(reason)}",
          detail: %{transport: inspect(reason)}
        )

        {:error, inspect(reason)}
    end
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
