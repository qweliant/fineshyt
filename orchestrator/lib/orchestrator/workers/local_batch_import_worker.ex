defmodule Orchestrator.Workers.LocalBatchImportWorker do
  use Oban.Worker,
    queue: :ai_jobs,
    max_attempts: 2

  require Logger

  # Formats Pillow can open natively in the ai_worker
  @pillow_exts ~w(.tif .tiff .jpg .jpeg .png .webp .bmp .tga .psd)
  # Camera RAW formats handled by rawpy in the ai_worker
  @raw_exts ~w(.cr2 .cr3 .nef .arw .dng .raf .orf .rw2 .pef .srw .x3f .3fr .erf .mef .mos .nrw .raw)
  @all_exts MapSet.new(@pillow_exts ++ @raw_exts)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"dir_path" => dir_path} = args
      }) do
    sample = Map.get(args, "sample")
    project = Map.get(args, "project")

    Logger.info("Starting local ingest from #{dir_path} (sample: #{inspect(sample)})...")

    with {:ok, file_paths} <- scan_directory(dir_path) do
      total_found = length(file_paths)

      sampled =
        case sample do
          n when is_integer(n) and n > 0 and n < total_found -> Enum.take_random(file_paths, n)
          _ -> file_paths
        end

      stems = Enum.map(sampled, fn p -> Path.rootname(Path.basename(p)) end)
      already_done = Orchestrator.Photos.existing_stems(stems)

      new_paths =
        Enum.reject(sampled, fn path ->
          MapSet.member?(already_done, Path.rootname(Path.basename(path)))
        end)

      skipped = length(sampled) - length(new_paths)
      if skipped > 0, do: Logger.info("Skipping #{skipped} already-processed files.")

      Logger.info(
        "Found #{length(sampled)}/#{total_found} files, queuing #{length(new_paths)} for conversion + curation..."
      )

      for file_path <- new_paths do
        ref = make_ref() |> inspect()

        %{
          "file_path" => file_path,
          "ref"       => ref,
          "source"    => "local",
          "project"   => project
        }
        |> Orchestrator.Workers.ConversionWorker.new()
        |> Oban.insert()
      end

      Phoenix.PubSub.broadcast(
        Orchestrator.PubSub,
        "photo_updates",
        {:import_started, length(new_paths)}
      )

      :ok
    else
      {:error, detail} ->
        Logger.error("Local ingest failed: #{detail}")
        Phoenix.PubSub.broadcast(Orchestrator.PubSub, "photo_updates", {:import_failed, detail})
        {:error, detail}
    end
  end

  defp scan_directory(dir_path) do
    cond do
      not File.dir?(dir_path) ->
        {:error, "Directory not found: #{dir_path}"}

      true ->
        files = walk(dir_path)

        if files == [] do
          {:error, "No supported image files found in #{dir_path}"}
        else
          {:ok, files}
        end
    end
  end

  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          # Skip dotfiles (incl. macOS ._sidecar resource forks)
          if String.starts_with?(entry, ".") do
            []
          else
            path = Path.join(dir, entry)

            cond do
              File.dir?(path) -> walk(path)
              File.regular?(path) and supported?(path) -> [path]
              true -> []
            end
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp supported?(path) do
    MapSet.member?(@all_exts, path |> Path.extname() |> String.downcase())
  end
end
