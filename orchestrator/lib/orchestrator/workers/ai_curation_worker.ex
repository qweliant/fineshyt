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
    project = Map.get(args, "project")
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

          form_fields =
            [file: {image_binary, filename: basename, content_type: "image/jpeg"}] ++
              if style_description != "", do: [style_description: style_description], else: []

          case Req.post("http://127.0.0.1:8000/api/v1/curate",
                 form_multipart: form_fields,
                 receive_timeout: 60_000
               ) do
            {:ok, %Req.Response{status: 200, body: metadata}} ->
              Photos.delete_failed_if_exists(dest)
              Photos.create_photo(%{
                file_path: dest,
                url: "/uploads/#{basename}",
                source: source,
                instagram_shortcode: instagram_shortcode,
                project: project,
                style_match: metadata["style_match"],
                style_score: metadata["style_score"],
                style_reason: metadata["style_reason"],
                subject: metadata["subject"],
                artistic_mood: metadata["artistic_mood"],
                lighting_critique: metadata["lighting_critique"],
                content_type: metadata["content_type"],
                suggested_tags: metadata["suggested_tags"],
                curation_status: "complete"
              })

              Logger.info("AI Curation successful for #{basename}!")
              Phoenix.PubSub.broadcast(
                Orchestrator.PubSub,
                "photo_updates",
                {:curation_complete, ref, metadata, basename}
              )
              :ok

            {:ok, %Req.Response{status: status}} ->
              Logger.error("Python API failed with status: #{status}")
              {:error, "API returned status #{status}"}

            {:error, reason} ->
              Logger.error("Failed to connect to AI service: #{inspect(reason)}")
              {:error, inspect(reason)}
          end
        end
      rescue
        e ->
          Logger.error("AI curation raised an exception: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    if result != :ok, do: maybe_broadcast_failure(ref, job, dest, basename, source, project, result)
    result
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
end
