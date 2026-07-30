defmodule Mix.Tasks.Fineshyt.MigrateToSqlite do
  @shortdoc "One-off: import photos exported from the old Postgres DB into SQLite"

  @moduledoc """
  Imports `photos` rows from a JSONL export of the pre-C3 Postgres database
  into the current SQLite database.

  This is a **one-off** migration for the C3 (Postgres → SQLite) switch. It is
  decoupled from how the old DB is reached: you produce a JSONL export with
  `psql`, then point this task at it.

  ## Producing the export

  Start a temporary Postgres bound to the old `fineshyt_pgdata` volume, then:

      docker exec <pg> psql -U postgres -d photo_curator_dev -t -A -c \\
        "COPY (SELECT row_to_json(t) FROM (
           SELECT id, file_path, url, source, instagram_shortcode, manual_match,
                  subject, artistic_mood, lighting_critique, is_macro,
                  suggested_tags, inserted_at, updated_at, user_rating, project,
                  curation_status, content_type, failure_reason, technical_score,
                  sharpness_score, exposure_score, clip_embedding::text AS clip_embedding,
                  preference_score, preference_model_version, burst_group,
                  captured_at, source_path, sidecar_synced_at
           FROM photos) t) TO STDOUT" > /tmp/photos_export.jsonl

  The `clip_embedding::text` cast is important — it serializes the pgvector
  column as `"[0.1,0.2,...]"`, which we parse back into a float list and
  re-`dump` through `Orchestrator.Embedding` into the SQLite BLOB column.

  ## Running

      DATABASE_PATH=orchestrator/priv/fineshyt.db \\
        mix fineshyt.migrate_to_sqlite /tmp/photos_export.jsonl

  The target SQLite DB must already be migrated (run `mix ecto.migrate` or the
  release `bin/migrate` first). The task refuses to run if the photos table is
  non-empty, so it can't accidentally double-import.
  """

  use Mix.Task

  import Ecto.Query

  alias Orchestrator.Repo
  alias Orchestrator.Photos.Photo

  @batch 500

  @impl Mix.Task
  def run(args) do
    path = List.first(args) || "/tmp/photos_export.jsonl"

    unless File.exists?(path) do
      Mix.raise("Export file not found: #{path}")
    end

    db = System.get_env("DATABASE_PATH") || Mix.raise("Set DATABASE_PATH to the target SQLite file")

    # Start ONLY the Repo (not the full app) so this one-off import doesn't
    # trigger boot hooks like the uploads-symlink reconciliation. Explicit
    # db path keeps it independent of env config. ecto_sql/exqlite must be
    # up first so the Ecto registry + SQLite driver exist.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    {:ok, _} = Repo.start_link(database: db, journal_mode: :wal, busy_timeout: 5_000, pool_size: 2)

    existing = Repo.aggregate(Photo, :count)

    if existing > 0 do
      Mix.raise(
        "Target photos table already has #{existing} rows — refusing to import. " <>
          "Start from a freshly-migrated empty SQLite DB."
      )
    end

    # The old rows stored file_path as the absolute uploads path at curation
    # time (an old _build/.../priv/static/uploads location). Rewrite the
    # directory to the uploads dir this install actually uses so file_path
    # stays valid for re-embedding / sidecar lookups. The gallery itself
    # displays via `url`, so this is belt-and-suspenders. No-op if unset.
    uploads_target = System.get_env("STATIC_UPLOADS_DIR")

    {count, _} =
      path
      |> File.stream!()
      |> Stream.map(&decode_row(&1, uploads_target))
      |> Stream.chunk_every(@batch)
      |> Enum.reduce({0, 0}, fn batch, {total, _} ->
        {n, _} = Repo.insert_all(Photo, batch)
        IO.puts("  imported #{total + n} / …")
        {total + n, n}
      end)

    final = Repo.aggregate(Photo, :count)
    with_emb = Repo.aggregate(from(p in Photo, where: not is_nil(p.clip_embedding)), :count)

    IO.puts("")
    IO.puts("Done. Inserted #{count} rows.")
    IO.puts("photos table now has #{final} rows (#{with_emb} with embeddings).")
  end

  defp decode_row(line, uploads_target) do
    json = Jason.decode!(line)

    %{
      id: json["id"],
      file_path: rewrite_file_path(json["file_path"], uploads_target),
      url: json["url"],
      source: json["source"],
      manual_match: json["manual_match"],
      subject: json["subject"],
      artistic_mood: json["artistic_mood"],
      lighting_critique: json["lighting_critique"],
      # NOTE: is_macro is a legacy column the current schema no longer maps,
      # so it's intentionally not imported.
      suggested_tags: json["suggested_tags"] || [],
      user_rating: json["user_rating"],
      project: json["project"],
      curation_status: json["curation_status"],
      content_type: json["content_type"],
      failure_reason: json["failure_reason"],
      technical_score: json["technical_score"],
      sharpness_score: json["sharpness_score"],
      exposure_score: json["exposure_score"],
      clip_embedding: parse_embedding(json["clip_embedding"]),
      preference_score: json["preference_score"],
      preference_model_version: json["preference_model_version"],
      burst_group: json["burst_group"],
      captured_at: parse_dt(json["captured_at"]),
      source_path: json["source_path"],
      sidecar_synced_at: parse_dt(json["sidecar_synced_at"]),
      inserted_at: parse_dt(json["inserted_at"]),
      updated_at: parse_dt(json["updated_at"])
    }
  end

  defp rewrite_file_path(nil, _), do: nil
  defp rewrite_file_path(fp, nil), do: fp
  defp rewrite_file_path(fp, target), do: Path.join(target, Path.basename(fp))

  # pgvector's ::text form is "[0.1,-0.2,...]". Parse to a float list; the
  # Photo schema's Orchestrator.Embedding type dumps it to a BLOB on insert.
  defp parse_embedding(nil), do: nil
  defp parse_embedding(""), do: nil

  defp parse_embedding(text) when is_binary(text) do
    text
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(fn n ->
      # Float.parse handles plain ("0"), decimal ("-0.02"), and exponent
      # ("1.5e-05") forms that pgvector's ::text may emit.
      {f, _} = Float.parse(String.trim(n))
      f
    end)
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    # row_to_json emits naive timestamps like "2026-04-01T12:34:56.123456".
    # Strip any trailing timezone offset to keep it naive.
    s
    |> String.replace(~r/(\+|-)\d{2}:?\d{2}$/, "")
    |> NaiveDateTime.from_iso8601()
    |> case do
      {:ok, ndt} -> NaiveDateTime.truncate(ndt, :second)
      _ -> nil
    end
  end
end
