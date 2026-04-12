defmodule Mix.Tasks.Fineshyt.ExifBackfill do
  use Mix.Task

  @shortdoc "Backfill captured_at from EXIF on original source files"

  @moduledoc """
  Walks the `photos` table for rows where `captured_at IS NULL`, looks up
  the original source file by stem in the given `--source` directory, calls
  the AI worker's `/api/v1/exif` endpoint, and writes the timestamp back.

  The converted JPEGs in `priv/static/uploads/` have EXIF stripped, so this
  task needs the directory where the originals (RAW or full-res JPEG) live.
  Matching is by filename stem (e.g., `DSC_1234.jpg` matches `DSC_1234.NEF`).

  Usage:

      mix fineshyt.exif_backfill --source /Volumes/Photos/originals

  Options:

    * `--source` (required) — directory containing original files with EXIF
  """

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [source: :string])
    source_dir = opts[:source] || raise "Usage: mix fineshyt.exif_backfill --source /path/to/originals"

    unless File.dir?(source_dir) do
      raise "Source directory not found: #{source_dir}"
    end

    Mix.Task.run("app.start")

    alias Orchestrator.Photos

    photos = Photos.list_photos_needing_captured_at()
    IO.puts("Found #{length(photos)} photos without captured_at.")

    if photos == [] do
      IO.puts("Nothing to do.")
    else
      # Build a stem → full-path index of the source directory.
      source_index = build_source_index(source_dir)
      IO.puts("Indexed #{map_size(source_index)} source files in #{source_dir}")

      {updated, skipped, failed} =
        photos
        |> Enum.reduce({0, 0, 0}, fn {id, file_path}, {upd, skip, fail} ->
          stem = Path.basename(file_path, Path.extname(file_path))

          case Map.get(source_index, stem) do
            nil ->
              {upd, skip + 1, fail}

            source_path ->
              case call_exif_endpoint(source_path) do
                {:ok, captured_at} when is_binary(captured_at) ->
                  case NaiveDateTime.from_iso8601(captured_at) do
                    {:ok, ndt} ->
                      Photos.override_curation(id, %{captured_at: ndt})
                      {upd + 1, skip, fail}

                    _ ->
                      {upd, skip, fail + 1}
                  end

                {:ok, nil} ->
                  # File has no EXIF DateTimeOriginal
                  {upd, skip + 1, fail}

                {:error, reason} ->
                  IO.puts("  EXIF error for #{stem}: #{reason}")
                  {upd, skip, fail + 1}
              end
          end
        end)

      IO.puts("Done. Updated: #{updated}, skipped (no match/no EXIF): #{skipped}, failed: #{failed}")
    end
  end

  defp build_source_index(dir) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(%{}, fn path, acc ->
      stem = Path.basename(path, Path.extname(path))
      # First match wins — prefer files closer to root
      Map.put_new(acc, stem, path)
    end)
  end

  defp call_exif_endpoint(file_path) do
    case Req.post("http://127.0.0.1:8000/api/v1/exif",
           json: %{file_path: file_path},
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"captured_at" => captured_at}}} ->
        {:ok, captured_at}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
