defmodule Orchestrator.Photos do
  import Ecto.Query
  alias Orchestrator.Repo
  alias Orchestrator.Photos.Photo

  def create_photo(attrs) do
    %Photo{}
    |> Photo.changeset(attrs)
    |> Repo.insert()
  end

  @page_size 60

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

  def page_size, do: @page_size

  defp base_query(:failed),   do: from(p in Photo, where: p.curation_status == "failed")
  defp base_query(:rejected), do: from(p in Photo, where: p.curation_status == "rejected")
  defp base_query(_),         do: from(p in Photo, where: p.curation_status not in ["rejected", "failed", "pending"])

  defp apply_filter(q, :all),      do: q
  defp apply_filter(q, :failed),   do: q
  defp apply_filter(q, :rejected), do: q
  defp apply_filter(q, :match),    do: where(q, [p], p.style_match == true)
  defp apply_filter(q, :no_match), do: where(q, [p], p.style_match == false)
  defp apply_filter(q, :rated),    do: where(q, [p], not is_nil(p.user_rating))
  defp apply_filter(q, :unrated),  do: where(q, [p], is_nil(p.user_rating))
  defp apply_filter(q, :for_projects), do: where(q, [p], not is_nil(p.user_rating) and p.user_rating >= 4 and (is_nil(p.project) or p.project == ""))
  defp apply_filter(q, _),         do: q

  defp apply_project_filter(q, nil), do: q
  defp apply_project_filter(q, ""),  do: q
  defp apply_project_filter(q, p),   do: where(q, [photo], photo.project == ^p)

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

  defp apply_sort(q, :newest),      do: order_by(q, [p], desc: p.inserted_at)
  defp apply_sort(q, :score_desc),  do: order_by(q, [p], [desc_nulls_last: p.style_score, desc: p.inserted_at])
  defp apply_sort(q, :score_asc),   do: order_by(q, [p], [asc_nulls_last: p.style_score, desc: p.inserted_at])
  defp apply_sort(q, :rating_desc), do: order_by(q, [p], [desc_nulls_last: p.user_rating, desc: p.inserted_at])
  defp apply_sort(q, _),            do: order_by(q, [p], desc: p.inserted_at)

  defp paginate(q, page) do
    offset = (page - 1) * @page_size
    q |> limit(@page_size) |> offset(^offset)
  end

  def list_style_matches do
    Repo.all(from p in Photo, where: p.style_match == true, order_by: [desc: p.inserted_at])
  end

  def shortcode_exists?(shortcode) when is_binary(shortcode) do
    Repo.exists?(from p in Photo, where: p.instagram_shortcode == ^shortcode)
  end

  def shortcode_exists?(_), do: false

  # Returns a MapSet of filename stems (no extension) already in the DB.
  # Used to deduplicate local ingest batches where source paths are RAW
  # but stored records have .jpg extensions — matched by stem only.
  def existing_stems(stems) do
    Repo.all(
      from p in Photo,
        where: fragment("regexp_replace(regexp_replace(file_path, '^.*/', ''), '\\.[^.]+$', '') = ANY(?)", ^stems)
          and p.curation_status not in ["failed"],
        select: fragment("regexp_replace(regexp_replace(file_path, '^.*/', ''), '\\.[^.]+$', '')")
    )
    |> MapSet.new()
  end

  # Returns a MapSet of urls already in the DB for the given basenames.
  # Used to deduplicate local ingest batches across runs.
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

  def get_photo!(id), do: Repo.get!(Photo, id)

  def rate_photo(id, rating) do
    get_photo!(id)
    |> Photo.changeset(%{user_rating: rating})
    |> Repo.update()
  end

  def set_project(id, project) do
    get_photo!(id)
    |> Photo.changeset(%{project: project})
    |> Repo.update()
  end

  def override_curation(id, attrs) do
    get_photo!(id)
    |> Photo.changeset(attrs)
    |> Repo.update()
  end

  def delete_tag(id, tag) do
    photo = get_photo!(id)
    new_tags = Enum.reject(photo.suggested_tags || [], &(String.downcase(&1) == String.downcase(tag)))
    photo |> Photo.changeset(%{suggested_tags: new_tags}) |> Repo.update()
  end

  @doc """
  Hard delete: removes the file from disk AND tombstones the row to "rejected"
  with `url: nil`. Used by the gallery's explicit delete button.
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
  Soft reject: marks the row as "rejected" but leaves the file on disk so the
  decision is reversible. Used by the loupe-view cull workflow ("x" key).
  """
  def reject_photo(id) do
    get_photo!(id)
    |> Photo.changeset(%{curation_status: "rejected"})
    |> Repo.update()
  end

  @doc """
  Restore a soft-rejected photo back to "complete". Only works when the file
  is still on disk (i.e. it was rejected via `reject_photo/1`, not
  `delete_photo/1`).
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
  Empty trash: hard-delete every soft-rejected photo (file + row gone).
  Returns `{deleted_count, missing_count}`.
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
  Bulk-set the project name for many photos at once. Empty string clears
  the project. Returns `{:ok, n_updated}`.
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

  @doc "Bulk soft-reject many photos."
  def bulk_reject(ids) when is_list(ids) do
    {n, _} =
      Repo.update_all(
        from(p in Photo, where: p.id in ^ids),
        set: [curation_status: "rejected", updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)]
      )

    {:ok, n}
  end

  @doc """
  Cull queue: photos that have been successfully curated but the user has not
  yet rated or rejected. Oldest first (FIFO) so the queue drains predictably.
  Returns full Photo structs.
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
  Rate queue: photos already given a rating, sorted ascending so the user
  re-examines borderline 1★/2★ shots first. Used in the loupe view's "rate"
  mode.
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

  @doc "Count of unrated photos awaiting cull. Cheap query for UI badges."
  def count_pending_cull do
    Repo.aggregate(
      from(p in Photo, where: p.curation_status == "complete" and is_nil(p.user_rating)),
      :count
    )
  end

  @doc "Count of rated photos."
  def count_rated do
    Repo.aggregate(
      from(p in Photo, where: p.curation_status == "complete" and not is_nil(p.user_rating)),
      :count
    )
  end

  @doc "Count of soft-rejected (trash) photos."
  def count_rejected do
    Repo.aggregate(from(p in Photo, where: p.curation_status == "rejected"), :count)
  end

  # Register a file as pending before the AI job runs.
  # The batch worker calls this so we can skip re-processing on reruns.
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

  def mark_curation_status(id, status) do
    get_photo!(id)
    |> Photo.changeset(%{curation_status: status})
    |> Repo.update()
  end

  def already_processed?(file_path) do
    Repo.exists?(from p in Photo,
      where: p.file_path == ^file_path and p.curation_status in ["complete", "rejected"]
    )
  end

  # Persist a permanently-failed curation so the user can see and retry it.
  def create_failed(attrs) do
    %Photo{}
    |> Photo.changeset(Map.put(attrs, :curation_status, "failed"))
    |> Repo.insert(
      on_conflict: [set: [failure_reason: attrs[:failure_reason] || attrs["failure_reason"], curation_status: "failed", updated_at: DateTime.utc_now()]],
      conflict_target: [:file_path]
    )
  end

  # Before a successful insert, wipe any prior failed record for the same path.
  def delete_failed_if_exists(file_path) do
    Repo.delete_all(from p in Photo, where: p.file_path == ^file_path and p.curation_status == "failed")
  end

  # Delete the failed record and return its attrs so the caller can re-queue.
  def retry_failed(id) do
    photo = get_photo!(id)
    {:ok, _} = Repo.delete(photo)
    {:ok, %{file_path: photo.file_path, source: photo.source || "local", project: photo.project}}
  end

  # Returns [{name, count, cover_url}] for every named project.
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
            order_by: [desc_nulls_last: p.style_score, desc: p.inserted_at],
            limit: 1,
            select: p.url
        )

      %{name: name, count: count, cover_url: cover}
    end)
  end

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

  # Photos approved for blog export: rated >= 4 stars OR style_score >= 75.
  # Unrated photos are never included. Newer first.
  def list_approved do
    Repo.all(
      from p in Photo,
        where: not is_nil(p.user_rating) and (p.user_rating >= 4 or p.style_score >= 75),
        order_by: [desc: p.inserted_at]
    )
  end

  # Returns a map of %{tag => mean_rating} for all rated photos.
  # This is the user's learned preference profile.
  def tag_affinity_profile do
    rated = Repo.all(from p in Photo, where: not is_nil(p.user_rating), select: {p.suggested_tags, p.user_rating})

    rated
    |> Enum.flat_map(fn {tags, rating} -> Enum.map(tags, &{String.downcase(&1), rating}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {tag, ratings} -> {tag, Enum.sum(ratings) / length(ratings)} end)
  end

  # Computes a 0-100 vibe score for a photo against the affinity profile.
  # Falls back to the LLM style_score when no profile exists yet.
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

  # Generates a suggested style description addendum based on the user's rating history.
  # Returns nil when there are not enough ratings to draw conclusions.
  def suggest_style_refinement(base_description \\ "") do
    profile = tag_affinity_profile()

    if map_size(profile) < 3 do
      nil
    else
      top = profile
        |> Enum.filter(fn {_, r} -> r >= 4.0 end)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(8)
        |> Enum.map(&elem(&1, 0))

      avoid = profile
        |> Enum.filter(fn {_, r} -> r <= 2.0 end)
        |> Enum.sort_by(&elem(&1, 1), :asc)
        |> Enum.take(5)
        |> Enum.map(&elem(&1, 0))

      if top == [] do
        nil
      else
        affinity = "Based on your ratings, photos with these qualities score well: #{Enum.join(top, ", ")}."
        avoidance = if avoid != [], do: " Tend to avoid: #{Enum.join(avoid, ", ")}.", else: ""
        insight = affinity <> avoidance

        if base_description != "" do
          base_description <> "\n\n[Rating-derived refinement: #{insight}]"
        else
          insight
        end
      end
    end
  end
end
