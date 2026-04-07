defmodule Orchestrator.Workers.ConversionWorker do
  use Oban.Worker,
    queue: :conversion,
    max_attempts: 3

  require Logger

  alias Orchestrator.ErrorLog

  @worker_name "ConversionWorker"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_path" => file_path} = args} = job) do
    ref               = Map.get(args, "ref", inspect(make_ref()))
    style_description = Map.get(args, "style_description", "")
    source            = Map.get(args, "source", "local")
    project           = Map.get(args, "project")

    Logger.info("Converting #{Path.basename(file_path)}...")

    case Req.post("http://127.0.0.1:8000/api/v1/convert",
           json: %{file_path: file_path},
           # rawpy on a large RAW file can take up to 60s
           receive_timeout: 60_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"jpeg_path" => jpeg_path}}} ->
        Logger.info("Converted #{Path.basename(file_path)} → #{Path.basename(jpeg_path)}")

        %{
          "file_path"         => jpeg_path,
          "ref"               => ref,
          "style_description" => style_description,
          "source"            => source,
          "project"           => project
        }
        |> Orchestrator.Workers.AiCurationWorker.new()
        |> Oban.insert()

        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        detail = get_in(body, ["detail"]) || "status #{status}"
        Logger.error("Conversion failed for #{Path.basename(file_path)}: #{inspect(detail)}")
        record_error(job, Path.basename(file_path), "API #{status}: #{inspect(detail)}", status: status, detail: body)
        {:error, inspect(detail)}

      {:error, reason} ->
        Logger.error("Could not reach convert API: #{inspect(reason)}")
        record_error(job, Path.basename(file_path), "Transport: #{inspect(reason)}", detail: %{transport: inspect(reason)})
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
