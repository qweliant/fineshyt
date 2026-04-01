defmodule Orchestrator.Workers.AiCurationWorker do
  use Oban.Worker,
    queue: :ai_jobs,
    max_attempts: 3

  require Logger

  alias Orchestrator.Photos

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"file_path" => file_path, "ref" => ref} = args
      } = job) do
    Logger.info("Starting AI curation for #{file_path}...")

    style_description = Map.get(args, "style_description", "")
    source = Map.get(args, "source", "upload")
    instagram_shortcode = Map.get(args, "instagram_shortcode")

    result =
      try do
        image_binary = File.read!(file_path)

        form_fields =
          [file: {image_binary, filename: Path.basename(file_path), content_type: "image/jpeg"}] ++
            if style_description != "", do: [style_description: style_description], else: []

        case Req.post("http://127.0.0.1:8000/api/v1/curate",
               form_multipart: form_fields,
               receive_timeout: 60_000
             ) do
          {:ok, %Req.Response{status: 200, body: metadata}} ->
            url = "/uploads/#{Path.basename(file_path)}"

            Photos.create_photo(%{
              file_path: file_path,
              url: url,
              source: source,
              instagram_shortcode: instagram_shortcode,
              style_match: metadata["style_match"],
              style_score: metadata["style_score"],
              style_reason: metadata["style_reason"],
              subject: metadata["subject"],
              artistic_mood: metadata["artistic_mood"],
              lighting_critique: metadata["lighting_critique"],
              is_macro: metadata["is_macro"],
              suggested_tags: metadata["suggested_tags"]
            })

            Logger.info("AI Curation successful for #{file_path}!")
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
