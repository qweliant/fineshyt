defmodule Orchestrator.Sidecars do
  @moduledoc """
  Reads and writes XMP sidecars next to source photo files.

  ## Why sidecars

  XMP is the universal interchange format for photo metadata: ratings,
  keywords, color labels, develop instructions. Every serious photo
  editor (Lightroom, darktable, Capture One, Bridge, ON1, exiftool) reads
  and writes them. By round-tripping our metadata through XMP, Fine.Shyt
  becomes interoperable with whatever editing tool the user already
  has, without requiring any vendor SDK.

  Sidecars sit beside the original source file with the same base name
  and an `.xmp` extension. For `IMG_4523.cr3`, the sidecar is
  `IMG_4523.xmp`. The original photo is never modified.

  ## Mode (FINESHYT_SIDECAR_MODE)

    * `"off"`        — read and write are both disabled.
    * `"read"`       — read existing sidecars to seed metadata on
                       ingest; never write back. Default.
    * `"read-write"` — read on ingest *and* write Fine.Shyt's metadata
                       back as XMP after curation completes.

  Read is always safe (we never modify originals). Write requires opt-in
  because the sidecar appears next to the user's RAW files and they may
  be sharing the folder with another editor.

  ## What we read

    * `xmp:Rating`  → `user_rating` (1..5)
    * `xmp:Label`   → seeds `manual_match` if label is "Pick" or "5"
    * `dc:subject`  → merged into `suggested_tags`

  ## What we write (read-write mode only)

  Standard fields that other editors will recognize:

    * `xmp:Rating`           ← `user_rating`
    * `dc:subject`           ← `suggested_tags`
    * `xmp:Label`            ← `"Pick"` if `manual_match`

  Custom Fine.Shyt namespace (`fineshyt:`) for fields no standard
  covers — other editors will ignore these silently:

    * `fineshyt:PreferenceScore`   ← `preference_score`
    * `fineshyt:Subject`           ← `subject`
    * `fineshyt:ArtisticMood`      ← `artistic_mood`
    * `fineshyt:LightingCritique`  ← `lighting_critique`
    * `fineshyt:ContentType`       ← `content_type`

  ## Conflict policy

  Before any write, we check `mtime(sidecar)` vs the photo's
  `sidecar_synced_at`. If the sidecar has been touched since our last
  write (i.e. the user's editor edited it), we skip the write and log
  a warning. The user can force an overwrite by clearing
  `sidecar_synced_at` on the photo row.

  ## Tooling

  We shell out to `exiftool` for both read and write. It's the de facto
  standard, handles every variant in the wild, runs as a single Perl
  binary distributed everywhere (Homebrew, apt, the Phoenix release
  Docker image). All operations go through `Orchestrator.AiWorker`-style
  helpers so failures are caught and logged but never fatal — sidecar
  problems should never block curation.
  """

  require Logger

  @type mode :: :off | :read | :read_write
  @type metadata :: %{
          optional(:rating) => 1..5,
          optional(:label) => String.t(),
          optional(:keywords) => [String.t()]
        }

  @doc """
  Returns the configured mode as an atom: `:off`, `:read`, or `:read_write`.

  Defaults to `:read` when unset (safe default — no writes to user files).
  """
  @spec mode() :: mode()
  def mode do
    case Application.get_env(:orchestrator, :sidecar_mode, "read") do
      "off"        -> :off
      "read"       -> :read
      "read-write" -> :read_write
      "read_write" -> :read_write
      other ->
        Logger.warning("Unknown FINESHYT_SIDECAR_MODE=#{inspect(other)}; defaulting to :read")
        :read
    end
  end

  @doc """
  Computes the sidecar path for a given source file.

  Strips the source extension and appends `.xmp`. So
  `/photos/wedding/IMG_001.cr3` → `/photos/wedding/IMG_001.xmp`.

  Editors disagree on whether to include the source extension in the
  sidecar name (`IMG_001.cr3.xmp` vs `IMG_001.xmp`). We use the
  extension-stripped form because it's what Lightroom, darktable, and
  Bridge default to. exiftool accepts either when reading.
  """
  @spec path_for(String.t()) :: String.t()
  def path_for(source_path) when is_binary(source_path) do
    Path.rootname(source_path) <> ".xmp"
  end

  @doc """
  Reads metadata from the sidecar at the given source path.

  Returns `{:ok, metadata}` with whatever standard fields exiftool
  could parse, or `:none` if no sidecar exists, or `{:error, reason}`
  on a parse/transport failure.

  Always safe: never modifies any file.
  """
  @spec read(String.t()) :: {:ok, metadata()} | :none | {:error, term()}
  def read(source_path) when is_binary(source_path) do
    sidecar = path_for(source_path)

    cond do
      not File.exists?(sidecar) ->
        :none

      mode() == :off ->
        :none

      true ->
        case run_exiftool([
               "-json",
               "-Rating",
               "-Label",
               "-Subject",
               "-Keywords",
               sidecar
             ]) do
          {:ok, output} -> parse_exiftool_json(output)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Writes Fine.Shyt's metadata into the XMP sidecar next to the given
  source file.

  No-op (returns `:skipped`) when:

    * `mode()` is not `:read_write`
    * The sidecar's mtime is newer than the photo's `sidecar_synced_at`
      (the user's editor has touched it since our last write)

  On success returns `{:ok, NaiveDateTime.t()}` — the timestamp the
  caller should persist as `sidecar_synced_at`.

  ## Parameters

    * `source_path` — absolute path of the original source file
    * `photo` — `%Orchestrator.Photos.Photo{}` whose fields populate the sidecar
  """
  @spec write(String.t(), map()) :: {:ok, NaiveDateTime.t()} | :skipped | {:error, term()}
  def write(source_path, photo) when is_binary(source_path) do
    if mode() != :read_write do
      :skipped
    else
      sidecar = path_for(source_path)

      cond do
        sidecar_newer_than_synced?(sidecar, photo) ->
          Logger.warning(
            "Skipping XMP write for #{Path.basename(sidecar)}: editor has modified it since last sync"
          )
          :skipped

        true ->
          do_write(sidecar, photo)
      end
    end
  end

  # ---- internals -------------------------------------------------------

  defp do_write(sidecar, photo) do
    # Use Map.get/2 throughout — works for both Ecto schema structs (which
    # don't implement Access) and plain maps.
    args =
      []
      |> add_arg("-XMP-xmp:Rating", Map.get(photo, :user_rating))
      |> add_arg("-XMP-xmp:Label", if(Map.get(photo, :manual_match) == true, do: "Pick"))
      |> add_arg_list("-XMP-dc:Subject", Map.get(photo, :suggested_tags))
      |> add_arg("-XMP-fineshyt:PreferenceScore", Map.get(photo, :preference_score))
      |> add_arg("-XMP-fineshyt:Subject", Map.get(photo, :subject))
      |> add_arg("-XMP-fineshyt:ArtisticMood", Map.get(photo, :artistic_mood))
      |> add_arg("-XMP-fineshyt:LightingCritique", Map.get(photo, :lighting_critique))
      |> add_arg("-XMP-fineshyt:ContentType", Map.get(photo, :content_type))

    case run_exiftool(args ++ ["-overwrite_original", sidecar]) do
      {:ok, _} ->
        {:ok, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)}

      {:error, reason} ->
        Logger.error("XMP write failed for #{Path.basename(sidecar)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_exiftool(args) do
    case System.cmd("exiftool", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:exiftool_exit, code, output}}
    end
  rescue
    e in ErlangError ->
      Logger.warning("exiftool not installed: #{Exception.message(e)}")
      {:error, :exiftool_missing}
  end

  defp parse_exiftool_json(output) do
    case Jason.decode(output) do
      {:ok, [entry | _]} when is_map(entry) ->
        meta =
          %{}
          |> maybe_put(:rating, normalize_rating(entry["Rating"]))
          |> maybe_put(:label, entry["Label"])
          |> maybe_put(:keywords, normalize_keywords(entry["Subject"], entry["Keywords"]))

        {:ok, meta}

      {:ok, _} ->
        :none

      {:error, reason} ->
        {:error, {:json_parse, reason}}
    end
  end

  defp normalize_rating(nil), do: nil
  defp normalize_rating(n) when is_integer(n) and n in 1..5, do: n
  defp normalize_rating(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} when i in 1..5 -> i
      _ -> nil
    end
  end
  defp normalize_rating(_), do: nil

  defp normalize_keywords(nil, nil), do: nil
  defp normalize_keywords(subject, keywords) do
    [subject, keywords]
    |> Enum.flat_map(fn
      list when is_list(list) -> list
      string when is_binary(string) -> String.split(string, ~r/\s*,\s*|\s*;\s*/, trim: true)
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp add_arg(args, _flag, nil), do: args
  defp add_arg(args, _flag, ""), do: args
  defp add_arg(args, flag, value), do: args ++ ["#{flag}=#{value}"]

  defp add_arg_list(args, _flag, nil), do: args
  defp add_arg_list(args, _flag, []), do: args
  defp add_arg_list(args, flag, list) when is_list(list) do
    # exiftool's repeated-flag syntax for list-valued tags
    Enum.reduce(list, args, fn item, acc -> acc ++ ["#{flag}=#{item}"] end)
  end
  defp add_arg_list(args, _flag, _), do: args

  defp sidecar_newer_than_synced?(sidecar, photo) do
    case File.stat(sidecar, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        synced = Map.get(photo, :sidecar_synced_at)

        cond do
          is_nil(synced) -> false
          true ->
            synced_posix =
              synced
              |> NaiveDateTime.to_erl()
              |> :calendar.datetime_to_gregorian_seconds()
              |> Kernel.-(:calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}))

            mtime > synced_posix
        end

      _ ->
        false
    end
  end
end
