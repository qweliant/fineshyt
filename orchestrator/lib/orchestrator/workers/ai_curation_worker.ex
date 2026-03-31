defmodule Orchestrator.Workers.AiCurationWorker do
  use Oban.Worker,
    queue: :ai_jobs,
    max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_path" => file_path, "ref" => ref}} = job) do
    Logger.info("

    for #{file_path}...")

    result =
      try do
        image_binary = File.read!(file_path)

        case Req.post("http://127.0.0.1:8000/api/v1/curate",
          form_multipart: [file: {image_binary, filename: Path.basename(file_path), content_type: "image/jpeg"}],
          receive_timeout: 60_000
        ) do
          {:ok, %Req.Response{status: 200, body: metadata}} ->
            Logger.info("AI Curation successful!")
            Phoenix.PubSub.broadcast(Orchestrator.PubSub, "photo_updates", {:curation_complete, ref, metadata})
            :ok

          {:ok, %Req.Response{status: status}} ->
            Logger.error("Python API failed with status: #{status}")
            {:error, "API returned status #{status}"}

          {:error, reason} ->
            Logger.error("Failed to connect to AI service: #{inspect(reason)}")
            {:error, inspect(reason)}
        end
      rescue
        e ->
          Logger.error("AI curation raised an exception: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    if result != :ok, do: maybe_broadcast_failure(ref, job)
    result
  end

  defp maybe_broadcast_failure(ref, %Oban.Job{attempt: attempt, max_attempts: max}) do
    if attempt >= max do
      Logger.info("All attempts exhausted, broadcasting failure for ref #{ref}")
      Phoenix.PubSub.broadcast(Orchestrator.PubSub, "photo_updates", {:curation_failed, ref, nil})
    end
  end
end
