defmodule Mix.Tasks.Fineshyt.DetectDupCopies do
  @shortdoc "Find filename-copy duplicates (X.jpg + X copy.jpg) and group them"

  @moduledoc """
  Scans every "complete" photo, normalises the filename (strip extension +
  macOS-style ` copy`, ` copy N`, ` (N)` suffixes), groups photos with the
  same canonical stem, and writes a shared `dup_group` integer to each
  member. Photos in a singleton group get `dup_group = nil`.

  ## What "keeper" means

  Within each group, the **keeper** is the one most likely to be the
  original — picked in this order:

    1. Filename WITHOUT a copy/paren suffix.
    2. Highest `user_rating`.
    3. Most recent `inserted_at`.

  The keeper is the photo you'd want to keep on `--reject-extras`.

  ## Run

      DATABASE_PATH=orchestrator/priv/fineshyt.db \\
        mix fineshyt.detect_dup_copies

  Optional flags:

    * `--reject-extras` — after grouping, soft-reject every non-keeper
      (`curation_status = "rejected"`). Reversible from the gallery's
      Rejected tab.

  Same data lives behind the gallery's **Copies** tab — clicking
  "Detect Copies" there enqueues the equivalent Oban job
  (`DupDetectionWorker`). This task exists for CLI runs (no Phoenix +
  Oban needed).
  """

  use Mix.Task

  alias Orchestrator.Photos
  alias Orchestrator.Repo

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [reject_extras: :boolean])
    reject_extras = Keyword.get(opts, :reject_extras, false)

    db = System.get_env("DATABASE_PATH") || Mix.raise("Set DATABASE_PATH to the SQLite file")

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Repo.start_link(database: db, journal_mode: :wal, busy_timeout: 10_000, pool_size: 2)

    IO.puts("Scanning for filename copies...")
    {n_groups, n_extras} = Photos.detect_and_assign_dup_groups()
    IO.puts("→ #{n_groups} group(s) covering #{n_extras + n_groups} photos (#{n_extras} extras).")

    if reject_extras and n_extras > 0 do
      extras_ids =
        Photos.list_dup_groups()
        |> Enum.flat_map(fn {_gid, [_keeper | rest]} -> Enum.map(rest, & &1.id) end)

      {:ok, n} = Photos.bulk_reject(extras_ids)
      IO.puts("→ soft-rejected #{n} extra copy/copies (reversible from gallery Rejected tab).")
    end

    if n_groups > 0 do
      IO.puts("")
      IO.puts("Top 5 groups by size:")

      Photos.list_dup_groups()
      |> Enum.sort_by(fn {_gid, members} -> -length(members) end)
      |> Enum.take(5)
      |> Enum.each(&print_group/1)
    end

    :ok
  end

  defp print_group({gid, [keeper | rest]}) do
    IO.puts("  group #{gid} (#{length(rest) + 1} photos):")
    IO.puts("    keeper: #{Path.basename(keeper.file_path)}")
    Enum.each(rest, fn p -> IO.puts("    extra:  #{Path.basename(p.file_path)}") end)
  end
end
