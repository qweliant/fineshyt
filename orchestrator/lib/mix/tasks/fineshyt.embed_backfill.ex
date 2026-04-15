defmodule Mix.Tasks.Fineshyt.EmbedBackfill do
  use Mix.Task

  @shortdoc "Enqueue CLIP embedding jobs for every photo that doesn't have one yet"

  @moduledoc """
  One-shot backfill that walks the `photos` table and enqueues an
  `Orchestrator.Workers.EmbeddingWorker` job for every "complete" row whose
  `clip_embedding` is still NULL. Run once after the migration that adds
  the `clip_embedding` column — new photos get their embedding automatically
  via `AiCurationWorker`.

  Jobs land on the `:embedding` queue, which is concurrency-bounded in
  `config/config.exs` so this is safe to run on a live orchestrator. Each
  job also triggers a debounced `PreferenceTrainWorker`, so once ~20 rated
  photos have embeddings the preference model will fit and backfill
  `preference_score` for everyone on its own.

  Usage:
      mix fineshyt.embed_backfill
  """

  def run(_args) do
    Mix.Task.run("app.start")

    alias Orchestrator.Photos
    alias Orchestrator.Workers.EmbeddingWorker

    ids = Photos.list_photos_needing_embedding()
    total = length(ids)
    IO.puts("Enqueuing #{total} embedding jobs...")

    ids
    |> Enum.chunk_every(200)
    |> Enum.with_index()
    |> Enum.each(fn {chunk, i} ->
      Enum.each(chunk, fn id ->
        EmbeddingWorker.new(%{photo_id: id}) |> Oban.insert()
      end)

      IO.puts("  #{min((i + 1) * 200, total)} / #{total}")
    end)

    IO.puts("Done. Watch /logs or the Oban dashboard for progress.")
  end
end
