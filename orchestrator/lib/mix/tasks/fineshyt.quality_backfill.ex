defmodule Mix.Tasks.Fineshyt.QualityBackfill do
  use Mix.Task

  @shortdoc "Backfill sharpness, exposure, and technical scores for photos missing them"

  @moduledoc """
  Walks the `photos` table for rows where `technical_score IS NULL`, calls
  the AI worker's `/api/v1/quality_scores` endpoint, and writes the three
  scores back (`technical_score`, `sharpness_score`, `exposure_score`).

  By default, scores are computed from the converted JPEGs in
  `priv/static/uploads/`. For better accuracy (the full-res image has more
  high-frequency detail for sharpness measurement), pass `--source` to point
  at the originals — matching is by filename stem, same as the EXIF backfill.

  Usage:

      mix fineshyt.quality_backfill
      mix fineshyt.quality_backfill --source /Volumes/Photos/originals
  """

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [source: :string])
    source_dir = opts[:source]

    if source_dir && !File.dir?(source_dir) do
      raise "Source directory not found: #{source_dir}"
    end

    Mix.Task.run("app.start")

    alias Orchestrator.Photos

    photos = Photos.list_photos_needing_quality_scores()
    total = length(photos)
    IO.puts("Found #{total} photos without quality scores.")

    if total == 0 do
      IO.puts("Nothing to do.")
    else
      source_index =
        if source_dir do
          idx = build_source_index(source_dir)
          IO.puts("Indexed #{map_size(idx)} source files in #{source_dir}")
          idx
        end

      {updated, skipped, failed} =
        photos
        |> Enum.with_index(1)
        |> Enum.reduce({0, 0, 0}, fn {{id, file_path}, i}, {upd, skip, fail} ->
          if rem(i, 50) == 0, do: IO.puts("  #{i} / #{total}")

          # Resolve the best available file for scoring.
          score_path = resolve_score_path(file_path, source_index)

          case call_quality_endpoint(score_path) do
            {:ok, scores} ->
              Photos.override_curation(id, %{
                technical_score: scores["technical_score"],
                sharpness_score: scores["sharpness_score"],
                exposure_score: scores["exposure_score"]
              })

              {upd + 1, skip, fail}

            {:error, reason} ->
              IO.puts("  Score error for #{Path.basename(file_path)}: #{reason}")
              {upd, skip, fail + 1}
          end
        end)

      IO.puts("Done. Updated: #{updated}, skipped: #{skipped}, failed: #{failed}")
    end
  end

  defp resolve_score_path(file_path, nil), do: file_path

  defp resolve_score_path(file_path, source_index) do
    stem = Path.basename(file_path, Path.extname(file_path))

    case Map.get(source_index, stem) do
      nil -> file_path
      source_path -> source_path
    end
  end

  defp build_source_index(dir) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(%{}, fn path, acc ->
      stem = Path.basename(path, Path.extname(path))
      Map.put_new(acc, stem, path)
    end)
  end

  defp call_quality_endpoint(file_path) do
    case Req.post(Orchestrator.AiWorker.url("/api/v1/quality_scores"),
           json: %{file_path: file_path},
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
