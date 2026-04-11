defmodule Orchestrator.Workers.BatchImportWorker do
  use Oban.Worker,
    queue: :ai_jobs,
    max_attempts: 2

  require Logger

  alias Orchestrator.Photos

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "source" => "instagram",
            "username" => username,
            "style_description" => style_description
          } = args
      }) do
    max_posts = Map.get(args, "max_posts", 50)

    Logger.info("Starting Instagram import for @#{username} (max #{max_posts} posts)...")

    case Req.post("http://127.0.0.1:8000/api/v1/download/instagram",
           json: %{username: username, max_posts: max_posts},
           receive_timeout: 300_000
         ) do
      {:ok,
       %Req.Response{status: 200, body: %{"file_paths" => file_paths, "shortcodes" => shortcodes}}} ->
        new_items =
          Enum.zip(file_paths, shortcodes)
          |> Enum.reject(fn {_path, shortcode} -> Photos.shortcode_exists?(shortcode) end)

        count = length(new_items)
        Logger.info("Downloaded #{length(file_paths)} posts, #{count} are new.")

        for {file_path, shortcode} <- new_items do
          ref = make_ref() |> inspect()

          %{
            "file_path" => file_path,
            "ref" => ref,
            "style_description" => style_description,
            "source" => "instagram",
            "instagram_shortcode" => shortcode
          }
          |> Orchestrator.Workers.AiCurationWorker.new()
          |> Oban.insert()
        end

        Phoenix.PubSub.broadcast(
          Orchestrator.PubSub,
          "photo_updates",
          {:import_started, count}
        )

        :ok

      {:ok, %Req.Response{status: 429, body: body}} ->
        detail =
          get_in(body, ["detail"]) ||
            "Instagram is rate-limiting requests. Wait a few minutes and try again."

        Logger.warning("Instagram rate-limited: #{detail}")
        Phoenix.PubSub.broadcast(Orchestrator.PubSub, "photo_updates", {:import_failed, detail})
        # Snooze the Oban job so it retries automatically in 5 minutes
        {:snooze, 300}

      {:ok, %Req.Response{status: status, body: body}} ->
        detail = get_in(body, ["detail"]) || "status #{status}"
        Logger.error("Instagram download failed (#{status}): #{detail}")
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
