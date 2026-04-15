defmodule Orchestrator.Photos do
  @moduledoc """
  Context for photo records: ingestion, querying, curation state, ratings,
  projects, and the vibe-score machinery used by the loupe view.

  All photo mutations flow through this module so that LiveViews and Oban
  workers share a single source of truth for queue ordering, soft-delete
  semantics, and project assignment.

  ## Lifecycle vocabulary

    * `"pending"`  — row exists, AI worker has not yet returned
    * `"complete"` — AI worker succeeded; the photo is in the gallery
    * `"failed"`   — AI worker exhausted retries; row carries `failure_reason`
    * `"rejected"` — soft-deleted via the cull workflow; file still on disk

  See `Orchestrator.Photos.Photo` for the schema layout.

  ## Function groups

    * **Ingest / lookup** — `create_photo/1`, `create_pending/3`,
      `create_failed/1`, `delete_failed_if_exists/1`, `retry_failed/1`,
      `mark_curation_status/2`, `already_processed?/1`,
      `existing_stems/1`, `existing_basenames/1`, `get_photo!/1`
    * **Listing / pagination** — `list_photos/1`, `count_photos/1`,
      `page_size/0`, `list_projects/0`, `list_projects_with_covers/0`,
      `list_approved/0`
    * **Mutation** — `rate_photo/2`, `set_project/2`, `override_curation/2`,
      `add_tag/2`, `delete_tag/2`
    * **Soft-delete lifecycle** — `delete_photo/1` (hard), `reject_photo/1`
      (soft), `restore_photo/1`, `empty_trash/0`
    * **Bulk** — `bulk_set_project/2`, `bulk_reject/1`
    * **Cull / rate workflow** — `list_cull_queue/1`, `list_rate_queue/1`,
      `count_pending_cull/0`, `count_rated/0`, `count_rejected/0`
    * **Vibe scoring** — `tag_affinity_profile/0`, `vibe_score/2`
  """

  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Photos.Photo

  # Preference score ≥ this → "✓ Match" (see GalleryLive). Sits just under
  # the median of 5★-rated photos (≈71), so matches skew to the top of 4★
  # and most of 5★.
  @match_threshold 70

  @doc """
  Preference-score threshold (0–100) at which a photo is considered a MATCH.

  Kept here so the context, LiveViews, and the export task all agree.
  """
  def match_threshold, do: @match_threshold

  @doc """
  Insert a new photo row from a free-form attribute map.

  Used directly by the AI curation worker when committing a successful
  curation. Goes through `Photo.changeset/2` so all validations apply.

  ## Parameters

    * `attrs` — map of photo attributes; `:file_path` is required.

  ## Returns

    * `{:ok, %Photo{}}` on success.
    * `{:error, %Ecto.Changeset{}}` on validation or constraint failure.

  ## Examples

      Orchestrator.Photos.create_photo(%{
        file_path: "/uploads/a.jpg",
        url: "/uploads/a.jpg",
        source: "local"
      })
  """
  def create_photo(attrs) do
    %Photo{}
    |> Photo.changeset(attrs)
    |> Repo.insert()
  end

  @page_size 60

  @doc """
  Fetch a paginated, filtered, sorted, optionally project-scoped page of
  photos for the gallery.

  ## Parameters

    * `opts` — keyword list:
      * `:page` — 1-indexed page number (default `1`)
      * `:filter` — one of `:all`, `:match`, `:no_match`, `:rated`,
        `:unrated`, `:for_projects`, `:failed`, `:rejected` (default `:all`).
        `:match` and `:no_match` key off `preference_score` plus the
        `manual_match` override.
      * `:sort` — one of `:newest`, `:preference_desc`, `:preference_asc`,
        `:rating_desc` (default `:newest`)
      * `:search` — substring matched against `subject` and `artistic_mood`
      * `:project` — restrict to photos with this project name

  ## Returns

    * `[%Photo{}]` — at most `page_size/0` rows.

  ## Examples

      Orchestrator.Photos.list_photos(filter: :for_projects, sort: :rating_desc)
  """
  def list_photos(opts \\ []) do
    page    = Keyword.get(opts, :page, 1)
    filter  = Keyword.get(opts, :filter, :all)
    sort    = Keyword.get(opts, :sort, :newest)
    search  = Keyword.get(opts, :search, "")
    project = Keyword.get(opts, :project, nil)

    base_query(filter)
    |> apply_filter(filter)
    |> apply_project_filter(project)
    |> apply_search(search)
    |> apply_sort(sort)
    |> paginate(page)
    |> Repo.all()
  end

  @doc """
  Count photos matching the same filter/search/project criteria as
  `list_photos/1`.

  Used by the gallery to compute the total page count for pagination.

  ## Parameters

    * `opts` — same shape as `list_photos/1` minus `:page` and `:sort`.

  ## Returns

    * `non_neg_integer()`

  ## Examples

      Orchestrator.Photos.count_photos(filter: :rejected)
  """
  def count_photos(opts \\ []) do
    filter  = Keyword.get(opts, :filter, :all)
    search  = Keyword.get(opts, :search, "")
    project = Keyword.get(opts, :project, nil)

    base_query(filter)
    |> apply_filter(filter)
    |> apply_project_filter(project)
    |> apply_search(search)
    |> Repo.aggregate(:count)
  end

  @doc """
  Return the gallery page size constant.

  Centralized so the LiveView and the context agree on the slice width.

  ## Returns

    * `pos_integer()` — currently `60`.

  ## Examples

      iex> Orchestrator.Photos.page_size()
      60
  """
  def page_size, do: @page_size

  defp base_query(:failed),   do: from(p in Photo, where: p.curation_status == "failed")
  defp base_query(:rejected), do: from(p in Photo, where: p.curation_status == "rejected")
  defp base_query(_),         do: from(p in Photo, where: p.curation_status not in ["rejected", "failed", "pending"])

  defp apply_filter(q, :all),      do: q
  defp apply_filter(q, :failed),   do: q
  defp apply_filter(q, :rejected), do: q
  defp apply_filter(q, :match),
    do: where(q, [p], p.manual_match == true or p.preference_score >= ^@match_threshold)

  defp apply_filter(q, :no_match),
    do:
      where(
        q,
        [p],
        (p.manual_match == false or is_nil(p.manual_match)) and
          (p.preference_score < ^@match_threshold or is_nil(p.preference_score))
      )
  defp apply_filter(q, :rated),    do: where(q, [p], not is_nil(p.user_rating))
  defp apply_filter(q, :unrated),  do: where(q, [p], is_nil(p.user_rating))
  defp apply_filter(q, :for_projects), do: where(q, [p], not is_nil(p.user_rating) and p.user_rating >= 4 and (is_nil(p.project) or p.project == ""))
  defp apply_filter(q, _),         do: q

  defp apply_project_filter(q, nil), do: q
  defp apply_project_filter(q, ""),  do: q
  defp apply_project_filter(q, p),   do: where(q, [photo], photo.project == ^p)

  @doc """
  Return all distinct project names assigned to non-rejected photos, sorted
  alphabetically.

  Used to populate the project chip selectors in both the gallery and the
  loupe view's side panel.

  ## Returns

    * `[String.t()]` — distinct, non-empty project names.

  ## Examples

      Orchestrator.Photos.list_projects()
      # => ["family-2026", "wabi-sabi"]
  """
  def list_projects do
    Repo.all(
      from p in Photo,
        where: not is_nil(p.project) and p.project != "" and p.curation_status != "rejected",
        select: p.project,
        distinct: true,
        order_by: p.project
    )
  end

  defp apply_search(q, ""), do: q
  defp apply_search(q, search) do
    term = "%#{search}%"
    where(q, [p], ilike(p.subject, ^term) or ilike(p.artistic_mood, ^term))
  end

  defp apply_sort(q, :newest),          do: order_by(q, [p], desc: p.inserted_at)
  defp apply_sort(q, :rating_desc),     do: order_by(q, [p], [desc_nulls_last: p.user_rating, desc: p.inserted_at])
  defp apply_sort(q, :preference_desc), do: order_by(q, [p], [desc_nulls_last: p.preference_score, desc: p.inserted_at])
  defp apply_sort(q, :preference_asc),  do: order_by(q, [p], [asc_nulls_last: p.preference_score, desc: p.inserted_at])
  defp apply_sort(q, _),                do: order_by(q, [p], desc: p.inserted_at)

  defp paginate(q, page) do
    offset = (page - 1) * @page_size
    q |> limit(@page_size) |> offset(^offset)
  end

  @doc """
  Return the subset of given filename stems that already exist in the DB.

  Used to deduplicate local ingest batches where the on-disk source files
  may be RAW (e.g. `.NEF`) while the stored records have `.jpg` extensions
  — matching by stem only avoids re-converting and re-curating photos
  we've already processed.

  Failed rows are intentionally excluded so retries are possible.

  ## Parameters

    * `stems` — list of filename stems (no extension).

  ## Returns

    * `MapSet.t(String.t())` — stems that already exist.
  """
  def existing_stems(stems) do
    Repo.all(
      from p in Photo,
        where: fragment("regexp_replace(regexp_replace(file_path, '^.*/', ''), '\\.[^.]+$', '') = ANY(?)", ^stems)
          and p.curation_status not in ["failed"],
        select: fragment("regexp_replace(regexp_replace(file_path, '^.*/', ''), '\\.[^.]+$', '')")
    )
    |> MapSet.new()
  end

  @doc """
  Return the subset of given basenames whose corresponding `priv/static/uploads`
  paths already exist in the DB.

  Used as a second-pass dedupe alongside `existing_stems/1` for local ingest.
  Failed rows are excluded so retries are possible.

  ## Parameters

    * `basenames` — list of `"foo.jpg"`-style basenames.

  ## Returns

    * `MapSet.t(String.t())` — basenames already on disk and recorded.
  """
  def existing_basenames(basenames) do
    paths = Enum.map(basenames, fn b ->
      Path.join([:code.priv_dir(:orchestrator), "static", "uploads", b]) |> to_string()
    end)
    Repo.all(from p in Photo,
      where: p.file_path in ^paths and p.curation_status not in ["failed"],
      select: p.file_path
    )
    |> Enum.map(&Path.basename/1)
    |> MapSet.new()
  end

  @doc """
  Fetch a photo by primary key, raising if it does not exist.

  ## Parameters

    * `id` — integer primary key.

  ## Returns

    * `%Photo{}` on success.

  ## Raises

    * `Ecto.NoResultsError` if the photo does not exist.
  """
  def get_photo!(id), do: Repo.get!(Photo, id)

  @doc """
  Set the user's 1–5 star rating on a photo.

  ## Parameters

    * `id` — photo primary key.
    * `rating` — integer in `1..5`.

  ## Returns

    * `{:ok, %Photo{}}` on success.
    * `{:error, %Ecto.Changeset{}}` if validation fails (e.g. rating out of range).

  ## Examples

      Orchestrator.Photos.rate_photo(42, 5)
  """
  def rate_photo(id, rating) do
    get_photo!(id)
    |> Photo.changeset(%{user_rating: rating})
    |> Repo.update()
  end

  @doc """
  Assign a single photo to a named project.

  Empty string clears the project. For batch assignment, prefer
  `bulk_set_project/2`.

  ## Parameters

    * `id` — photo primary key.
    * `project` — project name string (or `""` to clear).

  ## Returns

    * `{:ok, %Photo{}}` on success.
    * `{:error, %Ecto.Changeset{}}` on validation failure.

  ## Examples

      Orchestrator.Photos.set_project(42, "wabi-sabi")
  """
  def set_project(id, project) do
    get_photo!(id)
    |> Photo.changeset(%{project: project})
    |> Repo.update()
  end

  @doc """
  Update arbitrary curation fields on a photo.

  Used by gallery overrides — flipping `manual_match`, changing `subject`,
  etc. Whatever the changeset accepts.

  ## Parameters

    * `id` — photo primary key.
    * `attrs` — map of fields to cast.

  ## Returns

    * `{:ok, %Photo{}}` | `{:error, %Ecto.Changeset{}}`

  ## Examples

      Orchestrator.Photos.override_curation(42, %{manual_match: true})
  """
  def override_curation(id, attrs) do
    get_photo!(id)
    |> Photo.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Return every photo that has both a star rating and a CLIP embedding.

  This is the training set for the preference model: the
  `PreferenceTrainWorker` ships these to the AI worker's
  `/api/v1/preference/train` endpoint, which fits a Ridge regression on
  `{embedding → rating}`. Only "complete" photos are included — rejected
  and failed rows are excluded from the signal.

  ## Returns

    * `[{id, clip_embedding, user_rating}]` — a list of tuples, where
      `clip_embedding` is a `%Pgvector{}` you can `Pgvector.to_list/1` to
      marshal into JSON.
  """
  def list_rated_with_embeddings do
    Repo.all(
      from p in Photo,
        where:
          not is_nil(p.user_rating) and not is_nil(p.clip_embedding) and
            p.curation_status == "complete",
        select: {p.id, p.clip_embedding, p.user_rating}
    )
  end

  @doc """
  Return photos whose `preference_score` is stale relative to the current
  model version.

  A row is stale when it has an embedding but either has never been scored
  (`preference_model_version IS NULL`) or was scored by an older model.
  Used by the `PreferenceTrainWorker` to backfill after each retrain.

  ## Parameters

    * `current_version` — the latest model version integer; rows at or
      above this version are considered fresh.
    * `limit` — maximum number of rows to return (default 500, matches
      the backfill batch size).

  ## Returns

    * `[{id, clip_embedding}]`
  """
  def list_photos_needing_preference_score(current_version, limit \\ 500) do
    Repo.all(
      from p in Photo,
        where:
          not is_nil(p.clip_embedding) and p.curation_status == "complete" and
            (is_nil(p.preference_model_version) or p.preference_model_version < ^current_version),
        select: {p.id, p.clip_embedding},
        limit: ^limit
    )
  end

  @doc """
  Batch-update `preference_score` + `preference_model_version` on many photos
  in a single transaction.

  Deliberately narrower than `override_curation/2` because the
  `PreferenceTrainWorker` runs this in tight loops over hundreds of rows and
  each call only touches two columns. Uses `update_all/3` keyed by id.

  ## Parameters

    * `updates` — list of `{id, score, version}` tuples.

  ## Returns

    * `:ok` — always. Errors bubble up as Ecto exceptions.
  """
  def update_preference_scores(updates) when is_list(updates) do
    Repo.transaction(fn ->
      Enum.each(updates, fn {id, score, version} ->
        from(p in Photo, where: p.id == ^id)
        |> Repo.update_all(
          set: [preference_score: score, preference_model_version: version]
        )
      end)
    end)

    :ok
  end

  @doc """
  IDs of photos that still need a CLIP embedding.

  Used by the `fineshyt.embed_backfill` mix task to enqueue one
  `EmbeddingWorker` per row after the initial migration lands.

  ## Returns

    * `[integer]` — every "complete" photo id with `clip_embedding IS NULL`.
  """
  def list_photos_needing_embedding do
    Repo.all(
      from p in Photo,
        where: is_nil(p.clip_embedding) and p.curation_status == "complete",
        select: p.id,
        order_by: [asc: p.id]
    )
  end

  @doc """
  Return `{id, file_path}` for every "complete" photo missing quality scores.
  Used by the quality backfill task.
  """
  def list_photos_needing_quality_scores do
    Repo.all(
      from p in Photo,
        where:
          is_nil(p.technical_score) and p.curation_status == "complete",
        select: {p.id, p.file_path},
        order_by: [asc: p.id]
    )
  end

  @doc """
  Return `{id, file_path}` for every "complete" photo that still has
  `captured_at IS NULL`. Used by the EXIF backfill task.
  """
  def list_photos_needing_captured_at do
    Repo.all(
      from p in Photo,
        where: is_nil(p.captured_at) and p.curation_status == "complete",
        select: {p.id, p.file_path},
        order_by: [asc: p.id]
    )
  end

  # ── Burst detection ────────────────────────────────────────────────────────

  @doc """
  Return every "complete" photo that has a CLIP embedding, suitable for
  burst detection. Result shape matches the Python worker's expected input.

  ## Returns

    * `[{id, clip_embedding, sharpness_score, captured_at}]`
  """
  def list_photos_for_burst_detection do
    Repo.all(
      from p in Photo,
        where: not is_nil(p.clip_embedding) and p.curation_status == "complete",
        select: {p.id, p.clip_embedding, p.sharpness_score, p.captured_at}
    )
  end

  @doc """
  Write burst group assignments to the photos table.

  Clears old groups first (sets all `burst_group` to NULL) then writes the
  new assignments. Each entry in `assignments` is `{photo_id, group_id}`.

  ## Parameters

    * `assignments` — list of `{photo_id, group_id}` tuples.

  ## Returns

    * `:ok`
  """
  def assign_burst_groups(assignments) when is_list(assignments) do
    Repo.transaction(fn ->
      # Clear previous burst assignments
      from(p in Photo, where: not is_nil(p.burst_group))
      |> Repo.update_all(set: [burst_group: nil])

      Enum.each(assignments, fn {id, group_id} ->
        from(p in Photo, where: p.id == ^id)
        |> Repo.update_all(set: [burst_group: group_id])
      end)
    end)

    :ok
  end

  @doc """
  Return burst groups for the gallery — each group is a list of photos,
  ordered so the sharpest frame comes first.

  ## Returns

    * `[{group_id, [%Photo{}, ...]}]` — list of `{group_id, photos}` tuples,
      sorted by group_id. Within each group, photos are ordered by
      `sharpness_score DESC`.
  """
  def list_burst_groups do
    photos =
      Repo.all(
        from p in Photo,
          where: not is_nil(p.burst_group) and p.curation_status == "complete",
          order_by: [asc: p.burst_group, desc: p.sharpness_score]
      )

    Enum.group_by(photos, & &1.burst_group)
    |> Enum.sort_by(fn {group_id, _} -> group_id end)
  end

  @doc """
  Remove a tag (case-insensitive) from a photo's `suggested_tags` list.

  No-op if the tag is not present.

  ## Parameters

    * `id` — photo primary key.
    * `tag` — tag string to remove.

  ## Returns

    * `{:ok, %Photo{}}` | `{:error, %Ecto.Changeset{}}`
  """
  def delete_tag(id, tag) do
    photo = get_photo!(id)
    new_tags = Enum.reject(photo.suggested_tags || [], &(String.downcase(&1) == String.downcase(tag)))
    photo |> Photo.changeset(%{suggested_tags: new_tags}) |> Repo.update()
  end

  @doc """
  Hard-delete a photo: remove the file from disk and tombstone the row to
  `"rejected"` with `url: nil`.

  Used by the gallery's explicit delete button (and recursively by
  `empty_trash/0`). Irreversible — there is no undo. For a reversible
  decision use `reject_photo/1` instead.

  ## Parameters

    * `id` — photo primary key.

  ## Returns

    * `{:ok, %Photo{}}` after the row is updated. The on-disk file is best-effort
      removed (missing file is ignored).
    * `{:error, %Ecto.Changeset{}}` if the update fails.

  ## Examples

      Orchestrator.Photos.delete_photo(42)
  """
  def delete_photo(id) do
    photo = get_photo!(id)
    if photo.file_path && File.exists?(photo.file_path) do
      File.rm(photo.file_path)
    end
    photo
    |> Photo.changeset(%{curation_status: "rejected", url: nil})
    |> Repo.update()
  end

  @doc """
  Soft-reject a photo: mark the row `"rejected"` but leave the file on disk
  so the decision can be reversed via `restore_photo/1`.

  Used by the loupe view's `x` key during culling and by the gallery's
  multi-select "Reject" button.

  ## Parameters

    * `id` — photo primary key.

  ## Returns

    * `{:ok, %Photo{}}` | `{:error, %Ecto.Changeset{}}`

  ## Examples

      Orchestrator.Photos.reject_photo(42)
  """
  def reject_photo(id) do
    get_photo!(id)
    |> Photo.changeset(%{curation_status: "rejected"})
    |> Repo.update()
  end

  @doc """
  Restore a soft-rejected photo back to `"complete"` status.

  Only works when the file is still on disk — i.e. the photo was rejected
  via `reject_photo/1`, not via `delete_photo/1` or `empty_trash/0`.

  ## Parameters

    * `id` — photo primary key.

  ## Returns

    * `{:ok, %Photo{}}` on success.
    * `{:error, :not_rejected}` if the photo is not currently rejected.
    * `{:error, :file_missing}` if the underlying file no longer exists.
    * `{:error, %Ecto.Changeset{}}` on update failure.

  ## Examples

      Orchestrator.Photos.restore_photo(42)
  """
  def restore_photo(id) do
    photo = get_photo!(id)

    cond do
      photo.curation_status != "rejected" ->
        {:error, :not_rejected}

      is_nil(photo.file_path) or not File.exists?(photo.file_path) ->
        {:error, :file_missing}

      true ->
        photo
        |> Photo.changeset(%{curation_status: "complete"})
        |> Repo.update()
    end
  end

  @doc """
  Empty the trash: hard-delete every soft-rejected photo (both file and row).

  Walks every `"rejected"` row, removes the file when present, and deletes
  the DB row regardless. Counts how many had a missing file so the UI can
  surface drift.

  ## Returns

    * `{deleted, missing}` — both `non_neg_integer()`. `deleted` is the
      total number of rows removed; `missing` is the subset whose file was
      already absent on disk.

  ## Examples

      Orchestrator.Photos.empty_trash()
      # => {12, 0}
  """
  def empty_trash do
    rejected =
      Repo.all(from p in Photo, where: p.curation_status == "rejected")

    {deleted, missing} =
      Enum.reduce(rejected, {0, 0}, fn photo, {d, m} ->
        cond do
          is_nil(photo.file_path) ->
            Repo.delete(photo)
            {d + 1, m + 1}

          File.exists?(photo.file_path) ->
            File.rm(photo.file_path)
            Repo.delete(photo)
            {d + 1, m}

          true ->
            Repo.delete(photo)
            {d + 1, m + 1}
        end
      end)

    {deleted, missing}
  end

  @doc """
  Bulk-set the project name on a list of photos in a single update.

  Empty string (or all-whitespace) clears the project field. Bypasses the
  changeset for speed — there is no per-row validation here.

  ## Parameters

    * `ids` — list of photo primary keys.
    * `project` — project name string, or `""` to clear.

  ## Returns

    * `{:ok, n_updated}` where `n_updated :: non_neg_integer()`.

  ## Examples

      Orchestrator.Photos.bulk_set_project([1, 2, 3], "wabi-sabi")
      # => {:ok, 3}
  """
  def bulk_set_project(ids, project) when is_list(ids) do
    project = if is_binary(project), do: String.trim(project), else: ""
    project = if project == "", do: nil, else: project

    {n, _} =
      Repo.update_all(
        from(p in Photo, where: p.id in ^ids),
        set: [project: project, updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)]
      )

    {:ok, n}
  end

  @doc """
  Bulk soft-reject a list of photos in a single update.

  Equivalent to calling `reject_photo/1` on each id, but in one query and
  bypassing the changeset for speed. Files stay on disk; restore via
  `restore_photo/1`.

  ## Parameters

    * `ids` — list of photo primary keys.

  ## Returns

    * `{:ok, n_updated}` where `n_updated :: non_neg_integer()`.

  ## Examples

      Orchestrator.Photos.bulk_reject([4, 5, 6])
      # => {:ok, 3}
  """
  def bulk_reject(ids) when is_list(ids) do
    {n, _} =
      Repo.update_all(
        from(p in Photo, where: p.id in ^ids),
        set: [curation_status: "rejected", updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)]
      )

    {:ok, n}
  end

  @doc """
  Fetch the cull queue — photos successfully curated by the AI worker but
  not yet rated or rejected by the user.

  Returned oldest first (FIFO) so the queue drains predictably as the user
  works through it in the loupe view.

  ## Parameters

    * `opts` — keyword list:
      * `:limit` — max rows returned (default `500`).

  ## Returns

    * `[%Photo{}]`

  ## Examples

      Orchestrator.Photos.list_cull_queue(limit: 50)
  """
  def list_cull_queue(opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    Repo.all(
      from p in Photo,
        where: p.curation_status == "complete" and is_nil(p.user_rating),
        order_by: [asc: p.inserted_at, asc: p.id],
        limit: ^limit
    )
  end

  @doc """
  Fetch the rate queue — photos already given a user rating.

  Sorted ascending by `user_rating` so the user re-examines borderline
  1★/2★ shots first. Used in the loupe view's `:rate` mode for the second
  pass after culling.

  ## Parameters

    * `opts` — keyword list:
      * `:limit` — max rows returned (default `500`).

  ## Returns

    * `[%Photo{}]`

  ## Examples

      Orchestrator.Photos.list_rate_queue()
  """
  def list_rate_queue(opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    Repo.all(
      from p in Photo,
        where: p.curation_status == "complete" and not is_nil(p.user_rating),
        order_by: [asc: p.user_rating, desc: p.inserted_at],
        limit: ^limit
    )
  end

  @doc """
  Count photos awaiting cull (`"complete"` and unrated).

  Cheap aggregate used by UI badges in the navigation header and the
  loupe view's mode tabs.

  ## Returns

    * `non_neg_integer()`

  ## Examples

      iex> Orchestrator.Photos.count_pending_cull()
      0
  """
  def count_pending_cull do
    Repo.aggregate(
      from(p in Photo, where: p.curation_status == "complete" and is_nil(p.user_rating)),
      :count
    )
  end

  @doc """
  Count rated photos in the `"complete"` lane.

  Used by the loupe view's "Rate" tab badge.

  ## Returns

    * `non_neg_integer()`
  """
  def count_rated do
    Repo.aggregate(
      from(p in Photo, where: p.curation_status == "complete" and not is_nil(p.user_rating)),
      :count
    )
  end

  @doc """
  Count soft-rejected (trash) photos.

  Used by the gallery's "Rejected" filter tab to show how many entries the
  Empty Trash button would clear.

  ## Returns

    * `non_neg_integer()`
  """
  def count_rejected do
    Repo.aggregate(from(p in Photo, where: p.curation_status == "rejected"), :count)
  end

  @doc """
  Insert a `"pending"` placeholder row before the AI worker runs.

  The batch ingest path calls this so reruns can skip files that are
  already mid-flight or completed. Uses `on_conflict: :nothing` against
  `file_path` so re-issuing the same file is a safe no-op.

  ## Parameters

    * `file_path` — absolute path on disk.
    * `basename` — basename used to build the public `/uploads/...` URL.
    * `source` — `"local"`.

  ## Returns

    * `{:ok, %Photo{}}` — newly inserted row.
    * `{:ok, %Photo{}}` with the existing row when conflict short-circuits.
    * `{:error, %Ecto.Changeset{}}` on validation failure.
  """
  def create_pending(file_path, basename, source) do
    %Photo{}
    |> Photo.changeset(%{
      file_path: file_path,
      url: "/uploads/#{basename}",
      source: source,
      curation_status: "pending"
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:file_path])
  end

  @doc """
  Update the `curation_status` field on a single photo.

  Used by workers to advance the lifecycle (`pending` → `complete`,
  `complete` → `failed`, etc.) without touching any other field.

  ## Parameters

    * `id` — photo primary key.
    * `status` — one of `"pending"`, `"complete"`, `"failed"`, `"rejected"`.

  ## Returns

    * `{:ok, %Photo{}}` | `{:error, %Ecto.Changeset{}}`
  """
  def mark_curation_status(id, status) do
    get_photo!(id)
    |> Photo.changeset(%{curation_status: status})
    |> Repo.update()
  end

  @doc """
  Check whether a file path has already been completed or rejected.

  Used by the batch ingest path to skip files that need no further work.
  Failed and pending rows are *not* counted as processed so they can be
  retried.

  ## Parameters

    * `file_path` — absolute path on disk.

  ## Returns

    * `boolean()`
  """
  def already_processed?(file_path) do
    Repo.exists?(from p in Photo,
      where: p.file_path == ^file_path and p.curation_status in ["complete", "rejected"]
    )
  end

  @doc """
  Persist a permanently-failed curation row so the user can see and retry it.

  Called by the AI curation worker after Oban exhausts all retry attempts.
  Upserts on `file_path` so a re-failure on the same file overwrites the
  prior `failure_reason` rather than spawning duplicate rows.

  ## Parameters

    * `attrs` — map containing at minimum `:file_path` and `:failure_reason`.

  ## Returns

    * `{:ok, %Photo{}}` | `{:error, %Ecto.Changeset{}}`
  """
  def create_failed(attrs) do
    %Photo{}
    |> Photo.changeset(Map.put(attrs, :curation_status, "failed"))
    |> Repo.insert(
      on_conflict: [set: [failure_reason: attrs[:failure_reason] || attrs["failure_reason"], curation_status: "failed", updated_at: DateTime.utc_now()]],
      conflict_target: [:file_path]
    )
  end

  @doc """
  Delete any prior `"failed"` row for the given path.

  Called by the AI curation worker right before a successful insert so a
  retried photo doesn't leave a stale failure tombstone next to its
  successful sibling.

  ## Parameters

    * `file_path` — absolute path on disk.

  ## Returns

    * `{n_deleted, nil}` — Ecto's `delete_all/2` shape.
  """
  def delete_failed_if_exists(file_path) do
    Repo.delete_all(from p in Photo, where: p.file_path == ^file_path and p.curation_status == "failed")
  end

  @doc """
  Delete a failed photo row and return its attrs so the caller can re-queue.

  Used by the gallery's "retry" buttons (single + batch). Returning the
  attrs in a single tuple lets the caller enqueue an Oban job without
  needing to read the row a second time.

  ## Parameters

    * `id` — photo primary key (must be a `"failed"` row).

  ## Returns

    * `{:ok, %{file_path: String.t(), source: String.t(), project: String.t() | nil}}`
  """
  def retry_failed(id) do
    photo = get_photo!(id)
    {:ok, _} = Repo.delete(photo)
    {:ok, %{file_path: photo.file_path, source: photo.source || "local", project: photo.project}}
  end

  @doc """
  Return every named project with its photo count and a cover image URL.

  Used by the projects landing page to render the project grid. The cover
  is the highest-`preference_score` photo in that project (newest as tie-break).

  ## Returns

    * `[%{name: String.t(), count: non_neg_integer(), cover_url: String.t() | nil}]`

  ## Examples

      Orchestrator.Photos.list_projects_with_covers()
      # => [%{name: "wabi-sabi", count: 14, cover_url: "/uploads/x.jpg"}, ...]
  """
  def list_projects_with_covers do
    counts =
      Repo.all(
        from p in Photo,
          where: not is_nil(p.project) and p.project != "" and p.curation_status not in ["rejected", "failed"],
          group_by: p.project,
          select: {p.project, count(p.id)},
          order_by: p.project
      )

    Enum.map(counts, fn {name, count} ->
      cover =
        Repo.one(
          from p in Photo,
            where: p.project == ^name and not is_nil(p.url) and p.curation_status == "complete",
            order_by: [desc_nulls_last: p.preference_score, desc: p.inserted_at],
            limit: 1,
            select: p.url
        )

      %{name: name, count: count, cover_url: cover}
    end)
  end

  @doc """
  Append a tag to a photo's `suggested_tags`.

  Trims whitespace and dedupes case-insensitively. Empty strings are
  ignored. Duplicates are silently dropped — the call still succeeds and
  returns the unchanged photo.

  ## Parameters

    * `id` — photo primary key.
    * `tag` — tag string to append.

  ## Returns

    * `{:ok, %Photo{}}` | `{:error, %Ecto.Changeset{}}`
  """
  def add_tag(id, tag) do
    tag = String.trim(tag)
    photo = get_photo!(id)
    existing = Enum.map(photo.suggested_tags || [], &String.downcase/1)
    if tag != "" and String.downcase(tag) not in existing do
      new_tags = (photo.suggested_tags || []) ++ [tag]
      photo |> Photo.changeset(%{suggested_tags: new_tags}) |> Repo.update()
    else
      {:ok, photo}
    end
  end

  @doc """
  Fetch every photo approved for blog export.

  "Approved" means: a user rating exists *and* either the rating is ≥4,
  `manual_match` is true, or `preference_score` meets `match_threshold/0`.
  Unrated photos are never included so the user's deliberate judgment is
  always part of the cut.

  ## Returns

    * `[%Photo{}]` — newest first.
  """
  def list_approved do
    threshold = @match_threshold

    Repo.all(
      from p in Photo,
        where:
          not is_nil(p.user_rating) and
            (p.user_rating >= 4 or p.manual_match == true or p.preference_score >= ^threshold),
        order_by: [desc: p.inserted_at]
    )
  end

  @doc """
  Compute the user's learned tag preference profile from rating history.

  Walks every rated photo, lowercases each suggested tag, and computes the
  mean rating across all photos that carry that tag. The result is the
  user's implicit "what I like" signal — fed into `vibe_score/2`.

  ## Returns

    * `%{String.t() => float()}` — `%{tag => mean_rating}`. Empty when
      there are no rated photos yet.

  ## Examples

      Orchestrator.Photos.tag_affinity_profile()
      # => %{"street" => 4.2, "macro" => 2.1, ...}
  """
  def tag_affinity_profile do
    rated = Repo.all(from p in Photo, where: not is_nil(p.user_rating), select: {p.suggested_tags, p.user_rating})

    rated
    |> Enum.flat_map(fn {tags, rating} -> Enum.map(tags, &{String.downcase(&1), rating}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {tag, ratings} -> {tag, Enum.sum(ratings) / length(ratings)} end)
  end

  @doc """
  Compute a 0–100 "vibe score" for a photo against the user's affinity
  profile.

  Looks up each tag in the profile, drops misses, and averages the surviving
  ratings on the 1..5 scale before normalizing to 0..100. Returns `nil` when
  there is no signal — either an empty profile or a photo whose tags
  produced no matches — so the UI can fall back to `preference_score`.

  ## Parameters

    * `photo` — `%Photo{}` whose `suggested_tags` are scored.
    * `profile` — affinity profile from `tag_affinity_profile/0`.

  ## Returns

    * `0..100` integer on success.
    * `nil` when there is no signal.

  ## Examples

      profile = Orchestrator.Photos.tag_affinity_profile()
      Orchestrator.Photos.vibe_score(photo, profile)
      # => 78
  """
  def vibe_score(%Photo{suggested_tags: _tags}, profile) when map_size(profile) == 0 do
    nil
  end

  def vibe_score(%Photo{suggested_tags: []}, _profile), do: nil

  def vibe_score(%Photo{suggested_tags: tags}, profile) do
    scores = tags
      |> Enum.map(&Map.get(profile, String.downcase(&1)))
      |> Enum.reject(&is_nil/1)

    if scores == [] do
      nil
    else
      mean = Enum.sum(scores) / length(scores)
      round((mean - 1) / 4 * 100)  # normalize 1-5 → 0-100
    end
  end

end
