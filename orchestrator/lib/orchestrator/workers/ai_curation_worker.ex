defmodule Orchestrator.Workers.AiCurationWorker do
  use Oban.Worker,
    queue: :ai_jobs,
    max_attempts: 3
    # backoff: :exponential

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_path" => file_path, "ref" => ref}}) do
    Logger.info("Starting AI curation for #{file_path}...")
    image_binary = File.read!(file_path)

    case Req.post("http://127.0.0.1:8000/api/v1/curate",
      multipart: [{:file, image_binary, filename: Path.basename(file_path), content_type: "image/jpeg"}],
      receive_timeout: 60_000
    ) do
      {:ok, %Req.Response{status: 200, body: metadata}} ->
        Logger.info("AI Curation successful!")

        # Broadcast the result directly to the LiveView!
        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "photo_updates",
          {:curation_complete, ref, metadata}
        )
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.error("Python API failed with status: #{status}")
        {:error, "API returned status #{status}"}

      {:error, reason} ->
        Logger.error("Failed to connect to AI service: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
