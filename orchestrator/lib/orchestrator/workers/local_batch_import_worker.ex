defmodule Orchestrator.Workers.LocalBatchImportWorker do
  use Oban.Worker,
    queue: :ai_jobs,
    max_attempts: 2

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "dir_path" => dir_path,
          "style_description" => style_description
        } = args
      }) do
    sample = Map.get(args, "sample")

    Logger.info("Starting local TIFF ingest from #{dir_path} (sample: #{inspect(sample)})...")

    body = %{dir_path: dir_path, sample: sample}

    case Req.post("http://127.0.0.1:8000/api/v1/ingest/local",
           json: body,
           # Allow up to 10 minutes for large TIFF batches
           receive_timeout: 600_000
         ) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"file_paths" => file_paths, "total_found" => total_found}
       }} ->
        basenames = Enum.map(file_paths, &Path.basename/1)
        already_done = Orchestrator.Photos.existing_basenames(basenames)

        new_paths =
          Enum.reject(file_paths, fn path ->
            MapSet.member?(already_done, Path.basename(path))
          end)

        skipped = length(file_paths) - length(new_paths)
        if skipped > 0, do: Logger.info("Skipping #{skipped} already-processed files.")
        Logger.info("Converted #{length(file_paths)}/#{total_found} images, queuing #{length(new_paths)} new for AI curation...")

        for file_path <- new_paths do
          ref = make_ref() |> inspect()

          %{
            "file_path" => file_path,
            "ref" => ref,
            "style_description" => style_description,
            "source" => "local"
          }
          |> Orchestrator.Workers.AiCurationWorker.new()
          |> Oban.insert()
        end

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "photo_updates",
          {:import_started, length(new_paths)}
        )

        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        detail = get_in(body, ["detail"]) || "status #{status}"
        Logger.error("Local ingest failed (#{status}): #{detail}")
        Phoenix.PubSub.broadcast(Orchestrator.PubSub, "photo_updates", {:import_failed, detail})
        {:error, detail}

      {:error, reason} ->
        detail = "Could not reach AI worker — is it running? (#{inspect(reason)})"
        Logger.error(detail)
        Phoenix.PubSub.broadcast(Orchestrator.PubSub, "photo_updates", {:import_failed, detail})
        {:error, detail}
    end
  end
end
