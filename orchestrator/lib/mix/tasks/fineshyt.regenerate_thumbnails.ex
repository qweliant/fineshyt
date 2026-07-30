defmodule Mix.Tasks.Fineshyt.RegenerateThumbnails do
  @shortdoc "Re-convert source files for photos whose uploads JPEG is missing"

  @moduledoc """
  Regenerates missing converted JPEGs (gallery thumbnails) by re-running each
  affected photo's original `source_path` through the ai_worker's `/convert`
  endpoint and saving the result under the photo's existing `url` basename.

  Only photos whose `url` JPEG is absent from the uploads dir AND that still
  have a readable `source_path` are touched. The DB is read-only here — no
  rows are modified, only the on-disk JPEG is recreated.

  ## Prerequisites

    * ai_worker running (`docker compose --profile c2 up -d ai_worker`).
      llama-server is NOT needed — `/convert` doesn't call the LLM.
    * The source drive/library mounted so `source_path` files are readable.

  ## Run

      DATABASE_PATH=orchestrator/priv/fineshyt.db \\
      STATIC_UPLOADS_DIR=$(pwd)/orchestrator/priv/static/uploads \\
      AI_WORKER_URL=http://localhost:8000 \\
        mix fineshyt.regenerate_thumbnails
  """

  use Mix.Task

  import Ecto.Query

  alias Orchestrator.Repo
  alias Orchestrator.Photos.Photo

  @impl Mix.Task
  def run(_args) do
    db = System.get_env("DATABASE_PATH") || Mix.raise("Set DATABASE_PATH to the SQLite file")
    uploads = System.get_env("STATIC_UPLOADS_DIR") || Mix.raise("Set STATIC_UPLOADS_DIR")
    ai = System.get_env("AI_WORKER_URL") || "http://localhost:8000"

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Repo.start_link(database: db, pool_size: 2)

    photos =
      Repo.all(
        from p in Photo, where: not is_nil(p.source_path) and not is_nil(p.url), select: p
      )

    {regen, skipped, failed} =
      Enum.reduce(photos, {0, 0, 0}, fn p, {r, s, f} ->
        target = Path.join(uploads, Path.basename(p.url))

        cond do
          File.exists?(target) ->
            {r, s, f}

          not File.exists?(p.source_path) ->
            IO.puts("  skip (source missing): #{p.source_path}")
            {r, s + 1, f}

          true ->
            case convert(ai, uploads, p.source_path, target) do
              :ok ->
                IO.puts("  regenerated #{Path.basename(target)}")
                {r + 1, s, f}

              {:error, reason} ->
                IO.puts("  FAILED #{Path.basename(p.source_path)}: #{reason}")
                {r, s, f + 1}
            end
        end
      end)

    IO.puts("")
    IO.puts("Done. regenerated=#{regen} skipped(missing source)=#{skipped} failed=#{failed}")
  end

  # Convert source bytes via the ai_worker, then move the produced JPEG to the
  # photo's existing url basename so the stored `url` keeps resolving. The
  # worker picks its own output name (collision-avoidance), so we rename.
  defp convert(ai, uploads, source_path, target) do
    bin = File.read!(source_path)

    fields = [
      file: {bin, filename: Path.basename(source_path), content_type: "application/octet-stream"}
    ]

    case Req.post(ai <> "/api/v1/convert", form_multipart: fields, receive_timeout: 60_000) do
      {:ok, %Req.Response{status: 200, body: %{"jpeg_path" => jpeg_path}}} ->
        produced = Path.join(uploads, Path.basename(jpeg_path))

        if produced != target do
          File.rename!(produced, target)
        end

        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "API #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
