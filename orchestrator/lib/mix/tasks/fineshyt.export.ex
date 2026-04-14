defmodule Mix.Tasks.Fineshyt.Export do
  use Mix.Task

  @shortdoc "Export approved photos + photos.json manifest to a target directory"

  @moduledoc """
  Copies approved photos (rated, and either user_rating >= 4, manual_match
  true, or preference_score >= `Photos.match_threshold/0`) to a target
  directory and writes/updates a photos.json manifest.

  Export is additive — existing files in the target are not replaced.

  Usage:
      mix fineshyt.export --target /path/to/blog/public/photos
  """

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [target: :string])

    target =
      opts[:target] ||
        Mix.raise("Pass --target /path/to/dir, e.g.: mix fineshyt.export --target ~/blog/photos")

    Mix.Task.run("app.start")

    alias Orchestrator.Photos

    photos = Photos.list_approved()
    IO.puts("Found #{length(photos)} approved photos.")

    File.mkdir_p!(target)

    manifest_path = Path.join(target, "photos.json")

    existing =
      if File.exists?(manifest_path) do
        manifest_path |> File.read!() |> Jason.decode!()
      else
        []
      end

    existing_filenames = MapSet.new(existing, & &1["filename"])

    new_entries =
      Enum.flat_map(photos, fn photo ->
        basename = Path.basename(photo.file_path)

        if MapSet.member?(existing_filenames, basename) do
          []
        else
          dst = Path.join(target, basename)

          case File.cp(photo.file_path, dst) do
            :ok ->
              [
                %{
                  "filename" => basename,
                  "tags" => photo.suggested_tags,
                  "mood" => photo.artistic_mood,
                  "preference_score" => photo.preference_score,
                  "user_rating" => photo.user_rating,
                  "manual_match" => photo.manual_match,
                  "project" => photo.project,
                  "inserted_at" => DateTime.to_iso8601(photo.inserted_at)
                }
              ]

            {:error, reason} ->
              IO.puts("  [skip] #{basename} — #{reason}")
              []
          end
        end
      end)

    IO.puts("Exporting #{length(new_entries)} new photos (#{length(existing)} already exported).")

    # Prepend new entries (newer first) and write manifest
    merged = new_entries ++ existing
    File.write!(manifest_path, Jason.encode!(merged, pretty: true))

    IO.puts("Done. Manifest: #{manifest_path}")
  end
end
