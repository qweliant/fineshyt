defmodule OrchestratorWeb.GalleryLive do
  @moduledoc """
  Gallery grid view at `/gallery` — the multi-photo workhorse alongside
  the single-photo `OrchestratorWeb.ReviewLive`.

  Renders a paginated, filterable, sortable, optionally project-scoped
  grid of curated photos. Supports per-photo overrides (rating, score,
  match flag, tag editing, project assignment) and multi-select bulk
  operations (assign project, soft-reject, empty trash, restore).

  ## State

    * `:filter` — `:all`, `:match`, `:no_match`, `:rated`, `:unrated`,
      `:for_projects`, `:failed`, `:rejected`
    * `:sort` — `:newest`, `:preference_desc`, `:preference_asc`,
      `:rating_desc`
    * `:search` — substring filter on subject + mood
    * `:page` — current 1-indexed page
    * `:project_filter` — project name to scope to, or `nil`
    * `:projects` — string list for the project chip selectors
    * `:tag_profile` — affinity map from `Photos.tag_affinity_profile/0`
    * `:selected` — `MapSet` of selected photo ids for bulk ops
    * `:bulk_project` — buffered text for the bulk new-project input
    * `:photos`, `:total`, `:pages` — current page slice and pagination
      metadata, refreshed by `load_photos/1`

  ## PubSub

  Subscribes to `"photo_updates"` so the grid refreshes when the AI
  curation worker reports `:curation_complete` or `:curation_failed`.

  ## Soft-delete vs hard-delete

  The `x` keyboard shortcut and the bulk Reject button use
  `Photos.reject_photo/1` (soft, reversible). The per-photo "delete forever"
  button uses `Photos.delete_photo/1` (hard, file removed). The Rejected
  filter tab plus its Empty Trash button is the only way to hard-delete
  many photos at once.
  """

  use OrchestratorWeb, :live_view

  alias Orchestrator.Photos

  # ── HEEx atoms ───────────────────────────────────────────────────────────
  # Mirror the design's React atoms (kit.jsx). Each one collapses ~100 chars
  # of repeated Tailwind into one named tag so the survey + inspector
  # templates stay scannable.

  attr :strong, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-value-group phx-value-kind phx-value-index phx-value-id data-confirm title)
  slot :inner_block, required: true

  defp ghost_btn(assigns) do
    ~H"""
    <button
      class={[
        "font-sans uppercase tracking-[0.16em] text-[10px] font-bold px-3.5 py-2 transition-colors whitespace-nowrap cursor-pointer",
        @strong && "border border-[#111] bg-[#111] text-[#fcfbf9] hover:opacity-80",
        !@strong && "border border-[#d6d3cc] bg-white text-[#7a7a7a] hover:border-[#111] hover:text-[#111]"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :reason, :map, required: true
  attr :class, :string, default: ""

  defp reason_chip(assigns) do
    ~H"""
    <div class={["inline-flex items-center gap-2.5 border border-[#d6d3cc] px-2.5 py-1.5 bg-white", @class]}>
      <span class="w-[7px] h-[7px] rounded-full shrink-0" style={"background: #{reason_dot(@reason.type)};"}></span>
      <span class="font-sans uppercase tracking-[0.18em] text-[9px] font-semibold text-[#111] shrink-0">
        {@reason.label}
      </span>
      <span class="font-serif italic text-[13px] text-[#7a7a7a]">{@reason.text}</span>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :leader, :boolean, default: false
  attr :width, :string, default: "46px"
  attr :compact, :boolean, default: false

  defp metric_bar(assigns) do
    ~H"""
    <div class={["flex items-center gap-1.5", @compact && "flex-1"]}>
      <div
        class={["h-[5px] bg-[#e7e5e0] relative", @compact && "flex-1"]}
        style={if(@compact, do: "", else: "width: #{@width};")}
      >
        <div
          class={["absolute inset-0 h-full", @leader && "bg-[#111]", !@leader && "bg-[#d6d3cc]"]}
          style={"width: #{metric_pct(@value)}%;"}
        ></div>
      </div>
      <span class={[
        "font-mono text-[11px] tabular-nums min-w-[22px] text-right",
        is_nil(@value) && "text-[#a8a8a8]",
        @leader && !is_nil(@value) && "text-[#111] font-bold",
        @value && !@leader && "text-[#7a7a7a]"
      ]}>
        {@value || "—"}
      </span>
    </div>
    """
  end

  attr :photo_id, :any, required: true
  attr :keep_active, :boolean, default: false
  attr :size, :string, default: "md", values: ~w(sm md)

  defp action_bar(assigns) do
    ~H"""
    <div class="flex gap-1.5">
      <button
        phx-click="keep_frame"
        phx-value-id={@photo_id}
        class={[
          "flex-1 font-sans uppercase tracking-[0.16em] font-bold border transition-colors cursor-pointer",
          @size == "sm" && "text-[9px] py-1.5",
          @size == "md" && "text-[10px] py-2",
          @keep_active && "bg-[#eaf4ee] border-[#16966a] text-[#0f7d55]",
          !@keep_active && "bg-white border-[#d6d3cc] text-[#7a7a7a] hover:border-[#16966a]"
        ]}
      >
        ✓ Keep
      </button>
      <button
        phx-click="reject_frame"
        phx-value-id={@photo_id}
        class={[
          "flex-1 font-sans uppercase tracking-[0.16em] font-bold border bg-white border-[#d6d3cc] text-[#7a7a7a] hover:bg-[#f9efee] hover:border-[#dcb6b2] hover:text-[#a82a1f] transition-colors cursor-pointer",
          @size == "sm" && "text-[9px] py-1.5",
          @size == "md" && "text-[10px] py-2"
        ]}
      >
        ✕ Reject
      </button>
    </div>
    """
  end

  # Preference score ≥ this → "✓ Match" badge. Sits just under the median
  # of 5★-rated photos (≈71) — strict enough to skew toward actual 5★s
  # while still catching the top of 4★.
  @match_threshold 70

  @doc """
  LiveView mount. Subscribes to `"photo_updates"` and primes every assign
  with empty/default values, then loads the first page.

  ## Parameters

    * `_params`, `_session` — unused.
    * `socket` — the LiveView socket.

  ## Returns

    * `{:ok, socket}` with a fully populated assigns map.
  """
  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, "photo_updates")

    socket =
      socket
      |> assign(:filter, :all)
      |> assign(:sort, :vibe_desc)
      |> assign(:search, "")
      |> assign(:page, 1)
      |> assign(:project_filter, nil)
      |> assign(:projects, Photos.list_projects())
      |> assign(:tag_profile, Photos.tag_affinity_profile())
      |> assign(:selected, MapSet.new())
      |> assign(:bulk_project, "")
      |> assign(:burst_groups, [])
      |> assign(:dup_groups, [])
      # Per-group "I want to keep multiple frames" selections. Lives only in
      # this session; resolving a burst commits the selection to the DB by
      # rejecting non-kept members and clearing burst_group on kept ones.
      |> assign(:burst_keeps, %{})
      |> assign(:inspect_state, nil)
      |> assign(:match_threshold, @match_threshold)
      |> load_photos()

    {:ok, socket}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp query_opts(socket) do
    [
      filter: socket.assigns.filter,
      sort: socket.assigns.sort,
      search: socket.assigns.search,
      page: socket.assigns.page,
      project: socket.assigns.project_filter
    ]
  end

  defp load_photos(socket) do
    opts = query_opts(socket)

    if socket.assigns.sort == :vibe_desc do
      # Vibe is computed in-memory from the tag profile. Rank the whole
      # filtered library from a lightweight {id, tags, preference_score}
      # projection (NOT full structs — avoids decoding every clip_embedding
      # blob), slice the page's ids, then load only those 60 full rows.
      profile = socket.assigns.tag_profile

      ranked =
        Photos.list_for_vibe_ranking(opts)
        |> Enum.sort_by(
          fn {_id, tags, pref} ->
            {Photos.vibe_score_for_tags(tags, profile) || -1, pref || -1}
          end,
          :desc
        )

      total = length(ranked)
      pages = max(1, ceil(total / Photos.page_size()))

      page_ids =
        ranked
        |> Enum.drop((socket.assigns.page - 1) * Photos.page_size())
        |> Enum.take(Photos.page_size())
        |> Enum.map(&elem(&1, 0))

      assign(socket, photos: Photos.list_by_ids_ordered(page_ids), total: total, pages: pages)
    else
      total = Photos.count_photos(opts)
      pages = max(1, ceil(total / Photos.page_size()))
      assign(socket, photos: Photos.list_photos(opts), total: total, pages: pages)
    end
  end

  defp reload(socket, overrides) do
    socket
    |> assign(overrides)
    |> assign(:page, 1)
    |> load_photos()
  end

  # Enqueue a preference-model retrain. Oban's `unique` constraint on the
  # worker collapses a burst of rating keypresses into a single retrain
  # within a 5-minute window, so calling this on every star press is cheap.
  defp trigger_preference_retrain do
    Orchestrator.Workers.PreferenceTrainWorker.new(%{trigger: "rating_change"})
    |> Oban.insert()
  end

  # ── events ────────────────────────────────────────────────────────────────

  @doc """
  Dispatch every event raised by the gallery.

  ## Filtering & sorting

    * `"set_filter"` — `%{"filter" => name}`. Filter tab click. Resets
      `:selected` and reloads from page 1.
    * `"set_sort"` — `%{"sort" => name}`. Sort dropdown.
    * `"search"` — `%{"q" => string}`. Search box submit.
    * `"set_project_filter"` — `%{"project" => name}`. Project chip in
      the header (empty string clears).
    * `"page"` — `%{"n" => n}`. Pagination button.

  ## Per-photo actions

    * `"photo_keydown"` — `%{"id" => id, "key" => key}`. Keyboard while
      a photo card is focused: `1`–`5` rate, `p` pick (★5), `x`
      soft-reject, `m` toggle multi-select.
    * `"toggle_match"` — `%{"id" => id}`. Flip the `manual_match` boolean
      (a.k.a. "chef's pick"). Independent of the preference-driven MATCH
      badge.
    * `"rate"` — `%{"id" => id, "rating" => rating}`. Star strip click.
    * `"delete_tag"` — `%{"id" => id, "tag" => tag}`. Remove tag chip.
    * `"add_tag"` — `%{"id" => id, "value" => tag}`. New tag input submit.
    * `"set_project"` — `%{"_id" => id, "project" => project}`. Project
      assignment input on a single photo.
    * `"delete_photo"` — `%{"id" => id}`. Hard delete (file removed).
    * `"restore_photo"` — `%{"id" => id}`. Reverse a soft-reject from the
      Rejected tab.

  ## Failed photo recovery

    * `"retry_photo"` — `%{"id" => id}`. Re-queue a single failed photo.
    * `"retry_all_failed"` — re-queue every photo on the Failed tab.

  ## Multi-select

    * `"toggle_select"` — `%{"id" => id}`. Checkbox click.
    * `"select_all"` — select every photo on the current page.
    * `"clear_selection"` — clear `:selected`.

  ## Bulk operations

    * `"bulk_project_input"` — `%{"value" => v}`. Buffered text input.
    * `"bulk_assign_project"` — `%{"name" => name}`. Project chip click
      in the bulk toolbar.
    * `"bulk_assign_input"` — bulk new-project form submit.
    * `"bulk_reject"` — soft-reject every photo in `:selected`.
    * `"empty_trash"` — hard-delete every soft-rejected photo. Only
      enabled on the Rejected tab.

  ## Returns

    * `{:noreply, socket}`
  """
  @impl Phoenix.LiveView
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    atom =
      case filter do
        "match" -> :match
        "no_match" -> :no_match
        "rated" -> :rated
        "unrated" -> :unrated
        "failed" -> :failed
        "rejected" -> :rejected
        "for_projects" -> :for_projects
        "bursts" -> :bursts
        "copies" -> :copies
        _ -> :all
      end

    socket = socket |> assign(:selected, MapSet.new())

    socket =
      case atom do
        :bursts -> assign(socket, :burst_groups, Photos.list_burst_groups())
        :copies -> assign(socket, :dup_groups, Photos.list_dup_groups())
        _ -> socket
      end

    {:noreply, reload(socket, filter: atom)}
  end

  @impl Phoenix.LiveView
  def handle_event("set_sort", %{"sort" => sort}, socket) do
    atom =
      case sort do
        "vibe_desc" -> :vibe_desc
        "rating_desc" -> :rating_desc
        "preference_desc" -> :preference_desc
        "preference_asc" -> :preference_asc
        _ -> :newest
      end

    {:noreply, reload(socket, sort: atom)}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, reload(socket, search: String.trim(q))}
  end

  @impl Phoenix.LiveView
  def handle_event("set_project_filter", %{"project" => p}, socket) do
    project = if p == "", do: nil, else: p
    {:noreply, reload(socket, project_filter: project)}
  end

  @impl Phoenix.LiveView
  def handle_event("photo_keydown", %{"id" => id, "key" => key}, socket) do
    photo_id = String.to_integer(id)

    case key do
      k when k in ["1", "2", "3", "4", "5"] ->
        Photos.rate_photo(photo_id, String.to_integer(k))
        trigger_preference_retrain()
        {:noreply, socket |> assign(:tag_profile, Photos.tag_affinity_profile()) |> load_photos()}

      "p" ->
        Photos.rate_photo(photo_id, 5)
        trigger_preference_retrain()
        {:noreply, socket |> assign(:tag_profile, Photos.tag_affinity_profile()) |> load_photos()}

      "x" ->
        Photos.reject_photo(photo_id)
        {:noreply, socket |> assign(:tag_profile, Photos.tag_affinity_profile()) |> load_photos()}

      "m" ->
        handle_event("toggle_select", %{"id" => id}, socket)

      _ ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("page", %{"n" => n}, socket) do
    page = String.to_integer(n) |> max(1) |> min(socket.assigns.pages)
    {:noreply, socket |> assign(:page, page) |> load_photos()}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_match", %{"id" => id}, socket) do
    photo = Photos.get_photo!(String.to_integer(id))
    Photos.override_curation(photo.id, %{manual_match: !(photo.manual_match || false)})
    {:noreply, load_photos(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("rate", %{"id" => id, "rating" => rating_str}, socket) do
    Photos.rate_photo(String.to_integer(id), String.to_integer(rating_str))
    trigger_preference_retrain()
    {:noreply, socket |> assign(:tag_profile, Photos.tag_affinity_profile()) |> load_photos()}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_tag", %{"id" => id, "tag" => tag}, socket) do
    Photos.delete_tag(String.to_integer(id), tag)
    {:noreply, load_photos(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("add_tag", %{"id" => id, "value" => tag}, socket) do
    case Photos.add_tag(String.to_integer(id), tag) do
      {:ok, _} -> {:noreply, load_photos(socket)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not add tag.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("set_project", %{"_id" => id, "project" => project}, socket) do
    Photos.set_project(String.to_integer(id), String.trim(project))
    {:noreply, load_photos(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_photo", %{"id" => id}, socket) do
    Photos.delete_photo(String.to_integer(id))

    {:noreply,
     socket
     |> put_flash(:info, "Photo removed from archive.")
     |> assign(:tag_profile, Photos.tag_affinity_profile())
     |> load_photos()}
  end

  @impl Phoenix.LiveView
  def handle_event("retry_photo", %{"id" => id}, socket) do
    case Photos.retry_failed(String.to_integer(id)) do
      {:ok, %{file_path: fp, source: source, project: project}} ->
        ref = System.unique_integer([:positive]) |> to_string()

        Orchestrator.Workers.AiCurationWorker.new(%{
          "file_path" => fp,
          "ref" => ref,
          "source" => source,
          "project" => project
        })
        |> Oban.insert()

        {:noreply, socket |> put_flash(:info, "Re-queued for curation.") |> load_photos()}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not retry.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("retry_all_failed", _params, socket) do
    failed = Photos.list_photos(filter: :failed, page: 1)

    Enum.each(failed, fn photo ->
      ref = System.unique_integer([:positive]) |> to_string()
      Photos.retry_failed(photo.id)

      Orchestrator.Workers.AiCurationWorker.new(%{
        "file_path" => photo.file_path,
        "ref" => ref,
        "source" => photo.source || "local",
        "project" => photo.project
      })
      |> Oban.insert()
    end)

    {:noreply,
     socket |> put_flash(:info, "Re-queued #{length(failed)} failed photos.") |> load_photos()}
  end

  # ── multi-select & bulk ───────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("toggle_select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _, socket) do
    ids = Enum.map(socket.assigns.photos, & &1.id) |> MapSet.new()
    {:noreply, assign(socket, :selected, ids)}
  end

  def handle_event("clear_selection", _, socket) do
    {:noreply, assign(socket, :selected, MapSet.new())}
  end

  def handle_event("bulk_project_input", %{"value" => v}, socket) do
    {:noreply, assign(socket, :bulk_project, v)}
  end

  def handle_event("bulk_assign_project", %{"name" => name}, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    if ids == [] do
      {:noreply, socket}
    else
      {:ok, n} = Photos.bulk_set_project(ids, name)

      {:noreply,
       socket
       |> assign(:selected, MapSet.new())
       |> assign(:bulk_project, "")
       |> assign(:projects, Photos.list_projects())
       |> put_flash(:info, "Assigned #{n} photo#{if n == 1, do: "", else: "s"} to #{name}.")
       |> load_photos()}
    end
  end

  def handle_event("bulk_assign_input", _, socket) do
    name = String.trim(socket.assigns.bulk_project)

    if name == "",
      do: {:noreply, socket},
      else: handle_event("bulk_assign_project", %{"name" => name}, socket)
  end

  def handle_event("bulk_reject", _, socket) do
    ids = MapSet.to_list(socket.assigns.selected)

    if ids == [] do
      {:noreply, socket}
    else
      {:ok, n} = Photos.bulk_reject(ids)

      {:noreply,
       socket
       |> assign(:selected, MapSet.new())
       |> put_flash(:info, "Rejected #{n} photo#{if n == 1, do: "", else: "s"}.")
       |> load_photos()}
    end
  end

  def handle_event("empty_trash", _, socket) do
    {deleted, missing} = Photos.empty_trash()

    msg =
      "Trash emptied: #{deleted} row#{if deleted == 1, do: "", else: "s"} removed" <>
        if missing > 0,
          do: " (#{missing} file#{if missing == 1, do: "", else: "s"} were already gone)",
          else: ""

    {:noreply,
     socket
     |> put_flash(:info, msg)
     |> load_photos()}
  end

  def handle_event("restore_photo", %{"id" => id}, socket) do
    case Photos.restore_photo(String.to_integer(id)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Restored.") |> load_photos()}

      {:error, :file_missing} ->
        {:noreply, put_flash(socket, :error, "Cannot restore — file is gone from disk.")}

      _ ->
        {:noreply, socket}
    end
  end

  # ── burst detection ───────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("detect_bursts", _params, socket) do
    Orchestrator.Workers.BurstDetectionWorker.new(%{})
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Burst detection started — this takes a few seconds.")}
  end

  @impl Phoenix.LiveView
  def handle_event("keep_best", %{"group" => group_str}, socket) do
    group_id = String.to_integer(group_str)
    burst_groups = socket.assigns.burst_groups

    case List.keyfind(burst_groups, group_id, 0) do
      {^group_id, [_best | rest]} when rest != [] ->
        reject_ids = Enum.map(rest, & &1.id)
        {:ok, n} = Photos.bulk_reject(reject_ids)

        {:noreply,
         socket
         |> assign(:burst_groups, Photos.list_burst_groups())
         |> put_flash(
           :info,
           "Kept sharpest, rejected #{n} duplicate#{if n == 1, do: "", else: "s"}."
         )
         |> load_photos()}

      _ ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("keep_best_all", _params, socket) do
    burst_groups = socket.assigns.burst_groups

    reject_ids =
      Enum.flat_map(burst_groups, fn {_gid, [_best | rest]} ->
        Enum.map(rest, & &1.id)
      end)

    if reject_ids == [] do
      {:noreply, socket}
    else
      {:ok, n} = Photos.bulk_reject(reject_ids)

      {:noreply,
       socket
       |> assign(:burst_groups, Photos.list_burst_groups())
       |> put_flash(
         :info,
         "Kept sharpest per burst, rejected #{n} duplicate#{if n == 1, do: "", else: "s"}."
       )
       |> load_photos()}
    end
  end

  # Commit a user's explicit multi-keep selection for a burst. Rejects
  # any frame not in the selection set, then clears `burst_group` on the
  # kept ones so the group resolves and exits the survey list.
  @impl Phoenix.LiveView
  def handle_event("resolve_burst_group", %{"group" => group_str}, socket) do
    group_id = String.to_integer(group_str)
    keeps = Map.get(socket.assigns.burst_keeps, group_id, MapSet.new())

    case List.keyfind(socket.assigns.burst_groups, group_id, 0) do
      {^group_id, photos} when photos != [] ->
        all_ids = Enum.map(photos, & &1.id)
        kept_ids = Enum.filter(all_ids, &MapSet.member?(keeps, &1))
        reject_ids = all_ids -- kept_ids

        n_reject =
          if reject_ids == [] do
            0
          else
            {:ok, n} = Photos.bulk_reject(reject_ids)
            n
          end

        if kept_ids != [], do: Photos.clear_burst_group_for_photos(kept_ids)

        burst_keeps = Map.delete(socket.assigns.burst_keeps, group_id)

        {:noreply,
         socket
         |> assign(:burst_keeps, burst_keeps)
         |> assign(:burst_groups, Photos.list_burst_groups())
         |> put_flash(
           :info,
           "Kept #{length(kept_ids)}, rejected #{n_reject}."
         )
         |> load_photos()}

      _ ->
        {:noreply, socket}
    end
  end

  # Dismiss a burst the user judges to be a false positive (most common
  # cause: a batch of film scans that the CLIP+timestamp heuristic
  # mistakes for a digital burst). Just clears burst_group on every
  # member; the photos themselves are untouched.
  @impl Phoenix.LiveView
  def handle_event("dismiss_burst", %{"group" => group_str}, socket) do
    group_id = String.to_integer(group_str)
    {:ok, n} = Photos.clear_burst_group(group_id)

    {:noreply,
     socket
     |> assign(:burst_groups, Photos.list_burst_groups())
     |> put_flash(:info, "Dismissed burst (#{n} photos un-grouped).")
     |> load_photos()}
  end

  # ── filename-copy dedup (parallel to bursts, no ML — pure string match) ──

  @impl Phoenix.LiveView
  def handle_event("detect_copies", _params, socket) do
    Orchestrator.Workers.DupDetectionWorker.new(%{})
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Copy detection started — takes a second.")}
  end

  @impl Phoenix.LiveView
  def handle_event("keep_best_dup", %{"group" => group_str}, socket) do
    group_id = String.to_integer(group_str)

    case List.keyfind(socket.assigns.dup_groups, group_id, 0) do
      {^group_id, [_keeper | rest]} when rest != [] ->
        reject_ids = Enum.map(rest, & &1.id)
        {:ok, n} = Photos.bulk_reject(reject_ids)

        {:noreply,
         socket
         |> assign(:dup_groups, Photos.list_dup_groups())
         |> put_flash(:info, "Kept original, rejected #{n} cop#{if n == 1, do: "y", else: "ies"}.")
         |> load_photos()}

      _ ->
        {:noreply, socket}
    end
  end

  # Parallel to dismiss_burst — for when the filename match was correct
  # but the photos are legitimately distinct (e.g. CLIP failed to reject
  # them at threshold 0.95 despite being different scenes).
  @impl Phoenix.LiveView
  def handle_event("dismiss_dup", %{"group" => group_str}, socket) do
    group_id = String.to_integer(group_str)
    {:ok, n} = Photos.clear_dup_group(group_id)

    {:noreply,
     socket
     |> assign(:dup_groups, Photos.list_dup_groups())
     |> put_flash(:info, "Dismissed copy group (#{n} photos un-grouped).")
     |> load_photos()}
  end

  @impl Phoenix.LiveView
  def handle_event("keep_best_all_dup", _params, socket) do
    reject_ids =
      Enum.flat_map(socket.assigns.dup_groups, fn {_gid, [_keeper | rest]} ->
        Enum.map(rest, & &1.id)
      end)

    if reject_ids == [] do
      {:noreply, socket}
    else
      {:ok, n} = Photos.bulk_reject(reject_ids)

      {:noreply,
       socket
       |> assign(:dup_groups, Photos.list_dup_groups())
       |> put_flash(
         :info,
         "Kept the original in each group, rejected #{n} cop#{if n == 1, do: "y", else: "ies"}."
       )
       |> load_photos()}
    end
  end

  # ── per-frame keep/reject (used by the new SurveyTile UI) ─────────────────

  # "Keep" is mostly a visual affirmation — the photo is already in the group
  # by virtue of being un-rejected. If the user previously soft-rejected it
  # and is now changing their mind from the Inspector, restore it. Otherwise
  # this is a no-op the LV swallows.
  @impl Phoenix.LiveView
  def handle_event("keep_frame", %{"id" => id}, socket) do
    photo = Photos.get_photo!(String.to_integer(id))

    socket =
      case photo.curation_status do
        "rejected" ->
          case Photos.restore_photo(photo.id) do
            {:ok, _} -> socket
            _ -> socket
          end

        _ ->
          socket
      end

    # Burst photos use Keep as a multi-select toggle — the user can mark
    # several frames as "keep" before resolving the group all at once.
    # Copies stay on the existing single-keeper model.
    socket =
      case photo.burst_group do
        nil -> socket
        gid -> toggle_burst_keep(socket, gid, photo.id)
      end

    {:noreply, refresh_groups(socket)}
  end

  defp toggle_burst_keep(socket, group_id, photo_id) do
    keeps = socket.assigns.burst_keeps
    current = Map.get(keeps, group_id, MapSet.new())

    new_set =
      if MapSet.member?(current, photo_id),
        do: MapSet.delete(current, photo_id),
        else: MapSet.put(current, photo_id)

    keeps =
      if MapSet.size(new_set) == 0,
        do: Map.delete(keeps, group_id),
        else: Map.put(keeps, group_id, new_set)

    assign(socket, :burst_keeps, keeps)
  end

  def handle_event("reject_frame", %{"id" => id}, socket) do
    Photos.reject_photo(String.to_integer(id))

    socket =
      socket
      |> refresh_groups()
      |> adjust_inspector_after_reject(String.to_integer(id))

    {:noreply, socket}
  end

  # ── Inspector overlay ────────────────────────────────────────────────────

  def handle_event("open_inspector", %{"group" => g, "kind" => k, "index" => i}, socket) do
    state = %{
      group_id: String.to_integer(g),
      kind: if(k == "copy", do: :copy, else: :burst),
      active: String.to_integer(i),
      compare: nil,
      prev_active: 0,
      zoom: 2.6
    }

    {:noreply, assign(socket, :inspect_state, state)}
  end

  def handle_event("close_inspector", _params, socket) do
    {:noreply, assign(socket, :inspect_state, nil)}
  end

  def handle_event("set_active", %{"index" => i}, socket) do
    {:noreply, update_inspector(socket, fn st -> %{st | prev_active: st.active, active: String.to_integer(i)} end)}
  end

  def handle_event("toggle_compare", %{"index" => i}, socket) do
    idx = String.to_integer(i)

    {:noreply,
     update_inspector(socket, fn st ->
       %{st | compare: if(st.compare == idx, do: nil, else: idx)}
     end)}
  end

  def handle_event("cycle", %{"dir" => dir}, socket) do
    delta = if dir == "prev", do: -1, else: 1

    {:noreply,
     update_inspector(socket, fn st ->
       case inspector_frames(socket, st) do
         [_ | _] = frames ->
           n = length(frames)
           %{st | prev_active: st.active, active: rem(st.active + delta + n, n)}

         _ ->
           st
       end
     end)}
  end

  def handle_event("flip", _params, socket) do
    {:noreply,
     update_inspector(socket, fn st ->
       cond do
         is_integer(st.compare) and st.active == st.compare ->
           %{st | active: st.prev_active, prev_active: st.compare}

         is_integer(st.compare) ->
           %{st | prev_active: st.active, active: st.compare}

         true ->
           frames = inspector_frames(socket, st)
           n = max(length(frames), 1)
           %{st | prev_active: st.active, active: rem(st.active + 1, n)}
       end
     end)}
  end

  def handle_event("set_zoom", %{"zoom" => z}, socket) do
    {zoom, _} = Float.parse(z)
    {:noreply, update_inspector(socket, fn st -> %{st | zoom: zoom} end)}
  end

  def handle_event("inspector_keep", _params, socket) do
    case socket.assigns.inspect_state do
      nil ->
        {:noreply, socket}

      st ->
        case Enum.at(inspector_frames(socket, st), st.active) do
          %{id: id} -> handle_event("keep_frame", %{"id" => to_string(id)}, socket)
          _ -> {:noreply, socket}
        end
    end
  end

  def handle_event("inspector_reject", _params, socket) do
    case socket.assigns.inspect_state do
      nil ->
        {:noreply, socket}

      st ->
        case Enum.at(inspector_frames(socket, st), st.active) do
          %{id: id} -> handle_event("reject_frame", %{"id" => to_string(id)}, socket)
          _ -> {:noreply, socket}
        end
    end
  end

  # Inspector state helpers ------------------------------------------------

  defp update_inspector(socket, _fun) when socket.assigns.inspect_state == nil, do: socket

  defp update_inspector(socket, fun) do
    assign(socket, :inspect_state, fun.(socket.assigns.inspect_state))
  end

  defp inspector_frames(socket, %{kind: :burst, group_id: gid}) do
    case List.keyfind(socket.assigns.burst_groups, gid, 0) do
      {^gid, photos} -> photos
      _ -> []
    end
  end

  defp inspector_frames(socket, %{kind: :copy, group_id: gid}) do
    case List.keyfind(socket.assigns.dup_groups, gid, 0) do
      {^gid, photos} -> photos
      _ -> []
    end
  end

  defp inspector_frames(_socket, _), do: []

  defp refresh_groups(socket) do
    case socket.assigns.filter do
      :bursts ->
        socket
        |> assign(:burst_groups, Photos.list_burst_groups())
        |> load_photos()

      :copies ->
        socket
        |> assign(:dup_groups, Photos.list_dup_groups())
        |> load_photos()

      _ ->
        load_photos(socket)
    end
  end

  # After a reject from inside the inspector, the rejected frame disappears
  # from the group. Clamp `:active` so it still points at a real frame, and
  # close the overlay entirely if the group is now empty (or a singleton —
  # nothing left to compare against).
  defp adjust_inspector_after_reject(socket, _rejected_id) do
    case socket.assigns.inspect_state do
      nil ->
        socket

      st ->
        frames = inspector_frames(socket, st)
        n = length(frames)

        cond do
          n < 2 ->
            assign(socket, :inspect_state, nil)

          true ->
            active = min(st.active, n - 1)

            compare =
              cond do
                is_nil(st.compare) -> nil
                st.compare >= n -> nil
                st.compare == active -> nil
                true -> st.compare
              end

            assign(socket, :inspect_state, %{st | active: active, compare: compare})
        end
    end
  end

  # ── pubsub ────────────────────────────────────────────────────────────────

  @doc """
  Handle PubSub messages from `"photo_updates"`.

  ## Messages

    * `{:curation_complete, ref, metadata, basename}` — a photo finished
      curating. Refreshes the projects list, the tag affinity profile,
      and the current page.
    * `{:curation_failed, ref, basename, reason}` — Oban exhausted
      retries. Reloads the page so the Failed tab count stays fresh.
    * Anything else — ignored.

  ## Returns

    * `{:noreply, socket}`
  """
  @impl Phoenix.LiveView
  def handle_info({:curation_complete, _ref, _metadata, _basename}, socket) do
    {:noreply,
     socket
     |> assign(:tag_profile, Photos.tag_affinity_profile())
     |> assign(:projects, Photos.list_projects())
     |> load_photos()}
  end

  def handle_info({:preference_scores_updated, _version}, socket) do
    {:noreply, load_photos(socket)}
  end

  def handle_info({:burst_detection_complete, n_groups}, socket) do
    socket =
      if socket.assigns.filter == :bursts do
        assign(socket, :burst_groups, Photos.list_burst_groups())
      else
        socket
      end

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Detected #{n_groups} burst group#{if n_groups == 1, do: "", else: "s"}."
     )
     |> load_photos()}
  end

  def handle_info({:dup_detection_complete, n_groups}, socket) do
    socket =
      if socket.assigns.filter == :copies do
        assign(socket, :dup_groups, Photos.list_dup_groups())
      else
        socket
      end

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Detected #{n_groups} filename-copy group#{if n_groups == 1, do: "", else: "s"}."
     )
     |> load_photos()}
  end

  def handle_info({:curation_failed, _ref, _basename, _reason}, socket) do
    # Reload so failed tab count stays fresh
    {:noreply, load_photos(socket)}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  # ── view helpers for the Survey/Inspector UI ─────────────────────────────

  # Classify the keeper choice so the ReasonChip can show *why* one frame
  # was picked over the others. Keeper is always the first photo in the
  # sorted group; we compare it against the runner-up.
  @doc false
  def survey_reason(:copy, [_keeper]),
    do: %{type: :original, label: "ORIGINAL", text: "Resolved — only the original remains"}

  def survey_reason(:copy, [_keeper | rest]) do
    n = length(rest)

    text =
      if n == 1,
        do: "Kept the original — the other is a duplicate",
        else: "Kept the original — the others are duplicates"

    %{type: :original, label: "ORIGINAL", text: text}
  end

  def survey_reason(:burst, [_keeper]),
    do: %{type: :clear, label: "CLEAR PICK", text: "Only one frame survived"}

  def survey_reason(:burst, [keeper, runner_up | _] = photos) do
    ks = keeper.sharpness_score
    rs = runner_up.sharpness_score
    ke = keeper.exposure_score
    re_ = runner_up.exposure_score
    kt = keeper.technical_score
    rt = runner_up.technical_score
    kp = keeper.preference_score
    rp = runner_up.preference_score
    n = length(photos)

    sharp_tied? = is_integer(ks) and is_integer(rs) and ks == rs
    expo_tied? = is_integer(ke) and is_integer(re_) and ke == re_
    tech_tied? = is_integer(kt) and is_integer(rt) and kt == rt

    cond do
      # Sharpness AND exposure both tied — the real tiebreaker was downstream.
      sharp_tied? and expo_tied? and is_integer(kp) and is_integer(rp) and kp > rp ->
        %{
          type: :tie,
          label: "TIE-BREAK",
          text: "Sharp/Expo tied at #{ks}/#{ke} — kept higher preference (#{kp} vs #{rp})"
        }

      sharp_tied? and expo_tied? and tech_tied? ->
        %{
          type: :tie,
          label: "TIE-BREAK",
          text: "All scores tied — kept by ordering"
        }

      # Sharpness tied but exposure broke it.
      sharp_tied? and is_integer(ke) and is_integer(re_) and ke > re_ ->
        %{
          type: :tie,
          label: "TIE-BREAK",
          text: "Sharpness tied at #{ks} — kept the better exposure (#{ke} vs #{re_})"
        }

      is_integer(ks) and is_integer(rs) and ks - rs >= 30 ->
        %{
          type: :clear,
          label: "CLEAR PICK",
          text: "Sharpest of #{n} (#{ks} vs next-best #{rs})"
        }

      is_integer(ks) and is_integer(rs) and ks - rs in 1..6 ->
        %{
          type: :close,
          label: "CLOSE CALL",
          text: "Marginally sharper (#{ks} vs #{rs})"
        }

      is_integer(ks) and is_integer(rs) ->
        %{
          type: :clear,
          label: "CLEAR PICK",
          text: "Sharpest of #{n} (#{ks} vs next-best #{rs})"
        }

      true ->
        %{type: :clear, label: "CLEAR PICK", text: "Suggested keeper by composite score"}
    end
  end

  # For each metric, return the index of the unique leader, or -1 on ties /
  # missing values. Matches the SurveyTile's "▸" leader marker logic.
  @doc false
  def metric_leaders(photos) do
    %{
      sharp: leader_index(photos, :sharpness_score),
      exp: leader_index(photos, :exposure_score),
      tech: leader_index(photos, :technical_score),
      pref: leader_index(photos, :preference_score)
    }
  end

  defp leader_index(photos, key) do
    {best_idx, _best_val, tie?} =
      photos
      |> Enum.with_index()
      |> Enum.reduce({-1, nil, false}, fn {p, i}, {bi, bv, tie} ->
        case Map.get(p, key) do
          nil ->
            {bi, bv, tie}

          v when is_nil(bv) or v > bv ->
            {i, v, false}

          v when v == bv ->
            {bi, bv, true}

          _ ->
            {bi, bv, tie}
        end
      end)

    if tie?, do: -1, else: best_idx
  end

  # 0..100 → percent (min 2 so a zero still shows a sliver, matching the mock)
  defp metric_pct(nil), do: 0
  defp metric_pct(v) when is_integer(v), do: max(2, min(100, v))

  # Compact precision time for the bottom-of-tile + filmstrip caption.
  # We don't have sub-second precision on captured_at, so show seconds only.
  defp format_capture_time(nil), do: "—"

  defp format_capture_time(%NaiveDateTime{hour: h, minute: m, second: s}),
    do: "#{pad(h)}:#{pad(m)}:#{pad(s)}"

  defp format_group_date(nil), do: "—"

  defp format_group_date(%NaiveDateTime{year: y, month: mo, day: d}),
    do: "#{y}-#{pad(mo)}-#{pad(d)}"

  # If the file is named like "X copy.jpg" or "X (2).jpg", tag it with the
  # suffix; otherwise it's the original. Used by the copies-view tile chip.
  @doc false
  def copy_tag(path) do
    stem = path |> Path.basename() |> Path.rootname()

    cond do
      String.match?(stem, ~r/\s+copy(?:[\s_]\d+)?$/i) -> "copy"
      String.match?(stem, ~r/\s*\(\d+\)$/) -> "(#{Regex.run(~r/\((\d+)\)$/, stem) |> case do
        [_, n] -> n
        _ -> ""
      end})"
      true -> "original"
    end
  end

  # Grid template for the SurveyGroup. n<=3: even columns; n>3: 3 frame
  # columns + a 0.66fr MoreCell column.
  @doc false
  def grid_template(n, _overflow?) when n <= 3,
    do: "grid-template-columns: repeat(#{max(n, 1)}, minmax(0, 1fr));"

  def grid_template(_n, true), do: "grid-template-columns: repeat(3, minmax(0, 1fr)) 0.66fr;"
  def grid_template(_n, false), do: "grid-template-columns: repeat(3, minmax(0, 1fr));"

  # Reason chip background dot color
  defp reason_dot(:original), do: "#0f7d55"
  defp reason_dot(:clear), do: "#0f7d55"
  defp reason_dot(:tie), do: "#b94900"
  defp reason_dot(:close), do: "#b94900"
  defp reason_dot(_), do: "#7a7a7a"

  defp inspector_kind_word(:copy), do: "Copy group"
  defp inspector_kind_word(_), do: "Burst"

  defp word_for(:copy), do: "Copies"
  defp word_for(_), do: "Burst"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"

  # ── render ────────────────────────────────────────────────────────────────

  @doc """
  Render the gallery grid.

  Light theme matching the FINESHYT serif aesthetic. Header carries the
  filter tabs, sort dropdown, search box, and project chip selector. The
  grid renders one card per `@photos` entry with hover overlays branching
  three ways via `cond` — failed (red), rejected (with restore + delete
  forever), or normal (with rate / project / tag controls). The bulk
  action toolbar is only visible when `MapSet.size(@selected) > 0`.

  ## Parameters

    * `assigns` — the LiveView assigns map.

  ## Returns

    * `Phoenix.LiveView.Rendered.t()`
  """
  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#fcfbf9] text-[#111111] font-serif p-6 md:p-12 lg:p-24">
      <%!-- Header --%>
      <header class="mb-12 border-b-[3px] border-[#111111] pb-6 flex flex-col md:flex-row md:items-end justify-between">
        <div>
          <h1 class="text-6xl md:text-8xl font-black tracking-tight leading-none">
            FINESHYT.
          </h1>
          <p class="mt-4 text-lg font-light italic text-gray-600">
            The Archive.
            <span class="font-sans text-sm not-italic text-gray-400">{@total} photos</span>
          </p>
        </div>
        <div class="mt-6 md:mt-0 font-sans uppercase tracking-widest text-xs flex gap-6">
          <.link
            navigate={~p"/review"}
            class="border-b border-[#111111] pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors"
          >
            Review →
          </.link>
          <.link
            navigate={~p"/projects"}
            class="border-b border-gray-400 pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors"
          >
            Projects
          </.link>
          <.link
            navigate={~p"/"}
            class="border-b border-gray-400 pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors"
          >
            ← Ingest
          </.link>
        </div>
      </header>

      <%!-- Search + Sort bar (hidden on Bursts/Copies — those tabs replace the whole view) --%>
      <div :if={@filter not in [:bursts, :copies]} class="flex flex-col sm:flex-row gap-4 mb-8">
        <form phx-change="search" class="flex-1 relative">
          <input
            type="text"
            placeholder="search subjects, mood…"
            value={@search}
            phx-debounce="300"
            name="q"
            class="w-full border border-gray-300 bg-transparent px-4 py-2.5 font-sans text-sm focus:outline-none focus:border-[#111111] placeholder-gray-300"
          />
          <%= if @search != "" do %>
            <button
              type="button"
              phx-click="search"
              phx-value-q=""
              class="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-700 font-sans text-sm"
            >
              ×
            </button>
          <% end %>
        </form>
        <form phx-change="set_sort">
          <select
            name="sort"
            class="border border-gray-300 bg-[#fcfbf9] px-4 py-2.5 font-sans text-xs uppercase tracking-widest focus:outline-none focus:border-[#111111] cursor-pointer"
          >
            <option value="vibe_desc" selected={@sort == :vibe_desc}>Vibe ↓</option>
            <option value="newest" selected={@sort == :newest}>Newest</option>
            <option value="preference_desc" selected={@sort == :preference_desc}>Preference ↓</option>
            <option value="preference_asc" selected={@sort == :preference_asc}>Preference ↑</option>
            <option value="rating_desc" selected={@sort == :rating_desc}>Rating ↓</option>
          </select>
        </form>
      </div>

      <%!-- Filter Tabs --%>
      <div class="flex gap-0 mb-4 border-b border-gray-200 overflow-x-auto">
        <%= for {label, value} <- [
          {"All", :all},
          {"For Projects", :for_projects},
          {"Match ✓", :match}, {"No Match ✗", :no_match},
          {"Rated", :rated}, {"Unrated", :unrated},
          {"Bursts", :bursts},
          {"Copies", :copies},
          {"Rejected", :rejected}, {"Failed", :failed}
        ] do %>
          <button
            phx-click="set_filter"
            phx-value-filter={value}
            class={[
              "font-sans uppercase tracking-widest text-xs px-5 py-3 border-b-2 transition-colors whitespace-nowrap shrink-0",
              (@filter == value and value in [:failed, :rejected]) && "border-red-600 text-red-600",
              (@filter == value and value not in [:failed, :rejected]) &&
                "border-[#111111] text-[#111111]",
              (@filter != value and value in [:failed, :rejected]) &&
                "border-transparent text-red-300 hover:text-red-500",
              (@filter != value and value not in [:failed, :rejected]) &&
                "border-transparent text-gray-400 hover:text-gray-600"
            ]}
          >
            {label}
          </button>
        <% end %>
      </div>

      <%!-- Rejected tab actions --%>
      <%= if @filter == :rejected and @total > 0 do %>
        <div class="flex items-center gap-4 mb-6 p-3 border border-red-200 bg-red-50/50">
          <p class="font-sans text-xs text-red-600 flex-1">
            {@total} photo{if @total != 1, do: "s"} in trash. Click
            <span class="font-bold">restore</span>
            to bring one back, or <span class="font-bold">empty trash</span>
            to hard-delete the files.
          </p>
          <button
            phx-click="empty_trash"
            data-confirm={"Hard-delete all #{@total} rejected photos? This removes the files from disk."}
            class="font-sans text-[10px] uppercase tracking-widest text-red-700 border border-red-300 px-3 py-1.5 hover:border-red-600 transition-colors shrink-0"
          >
            Empty Trash
          </button>
        </div>
      <% end %>

      <%!-- Failed tab actions --%>
      <%= if @filter == :failed and @total > 0 do %>
        <div class="flex items-center gap-4 mb-6 p-3 border border-red-200 bg-red-50/50">
          <p class="font-sans text-xs text-red-600 flex-1">
            {@total} photo{if @total != 1, do: "s"} failed AI curation (timeout or service error).
          </p>
          <button
            phx-click="retry_all_failed"
            data-confirm="Re-queue all #{@total} failed photos?"
            class="font-sans text-[10px] uppercase tracking-widest text-red-700 border border-red-300 px-3 py-1.5 hover:border-red-600 transition-colors shrink-0"
          >
            Retry All
          </button>
        </div>
      <% end %>

      <%!-- Survey layer: shared Bursts/Copies browse view (Direction B) --%>
      <%= if @filter in [:bursts, :copies] do %>
        <% kind = if @filter == :copies, do: :copy, else: :burst %>
        <% groups = if kind == :copy, do: @dup_groups, else: @burst_groups %>
        <% detect_event = if kind == :copy, do: "detect_copies", else: "detect_bursts" %>
        <% keep_all_event = if kind == :copy, do: "keep_best_all_dup", else: "keep_best_all" %>

        <%!-- Group toolbar --%>
        <div class="flex items-center gap-4 py-3.5 border-b border-[#e7e5e0] mb-6 flex-wrap">
          <span class="font-sans uppercase tracking-[0.2em] text-[10.5px] font-semibold text-[#111] shrink-0">
            <%= length(groups) %> {word_for(kind) |> String.downcase()}<%= if length(groups) == 1, do: "", else: "s" %> to resolve
          </span>
          <span class="font-serif italic text-[13px] text-[#7a7a7a] flex-1 min-w-[200px]">
            <%= if kind == :copy do %>
              Filename duplicates — keep the original, drop the copies.
            <% else %>
              Near-identical frames — keep the sharpest, drop the rest.
            <% end %>
          </span>
          <.ghost_btn phx-click={detect_event}>
            <%= if kind == :copy, do: "Re-scan duplicates", else: "Detect bursts" %>
          </.ghost_btn>
          <%= if groups != [] do %>
            <.ghost_btn strong phx-click={keep_all_event}>
              Keep best — all
            </.ghost_btn>
          <% end %>
        </div>

        <%= if groups == [] do %>
          <div class="text-center py-20 text-[#a8a8a8] font-serif italic text-lg">
            <%= if kind == :copy do %>
              No filename-copy groups detected yet — click
              <span class="font-bold not-italic">Re-scan duplicates</span>
              to find photos that share a name modulo
              <code class="font-mono not-italic text-[12px]">copy</code>
              / <code class="font-mono not-italic text-[12px]">(N)</code> suffixes.
            <% else %>
              No burst groups detected yet — click
              <span class="font-bold not-italic">Detect bursts</span>
              to scan for visually similar photo sequences.
            <% end %>
          </div>
        <% end %>

        <%= for {group_id, photos} <- groups do %>
          <% [keeper | _] = photos %>
          <% n = length(photos) %>
          <% leaders = metric_leaders(photos) %>
          <% reason = survey_reason(kind, photos) %>
          <% visible = Enum.take(photos, 3) %>
          <% overflow? = n > 3 %>
          <% hidden_photos = if overflow?, do: Enum.drop(photos, 3), else: [] %>
          <% keeper_idx = Enum.find_index(photos, &(&1.id == keeper.id)) %>
          <% keeper_hidden? = is_integer(keeper_idx) and keeper_idx >= 3 %>
          <% dismiss_event = if kind == :copy, do: "dismiss_dup", else: "dismiss_burst" %>
          <% group_keeps = if kind == :burst, do: Map.get(@burst_keeps, group_id, MapSet.new()), else: MapSet.new() %>
          <% has_selection? = kind == :burst and MapSet.size(group_keeps) > 0 %>
          <% keep_best_event =
            cond do
              has_selection? -> "resolve_burst_group"
              kind == :copy -> "keep_best_dup"
              true -> "keep_best"
            end %>

          <div class="mb-10">
            <%!-- Group header --%>
            <div class="flex items-center gap-3.5 flex-wrap mb-3">
              <span class="font-sans font-black text-[15px] tracking-tight whitespace-nowrap">
                {String.upcase(word_for(kind))} {String.pad_leading("#{group_id}", 2, "0")}
              </span>
              <span class="font-mono text-[11px] text-[#a8a8a8]">
                {n} frames · {format_group_date(keeper.captured_at)}
              </span>
              <.reason_chip reason={reason} />
              <div class="flex-1"></div>
              <.ghost_btn phx-click={dismiss_event} phx-value-group={group_id}>
                <%= if kind == :copy, do: "Not duplicates", else: "Not a burst" %>
              </.ghost_btn>
              <.ghost_btn strong phx-click={keep_best_event} phx-value-group={group_id}>
                <%= if has_selection? do %>
                  Resolve · keep {MapSet.size(group_keeps)} ✓
                <% else %>
                  Keep suggested ✓
                <% end %>
              </.ghost_btn>
            </div>

            <%!-- Frame grid --%>
            <div class="grid gap-4 items-stretch" style={grid_template(n, overflow?)}>
              <%= for {photo, i} <- Enum.with_index(visible) do %>
                <% kept? =
                  cond do
                    has_selection? -> MapSet.member?(group_keeps, photo.id)
                    true -> photo.id == keeper.id
                  end %>
                <div class="flex flex-col">
                  <%!-- Tile (image + caption) --%>
                  <div
                    phx-click="open_inspector"
                    phx-value-group={group_id}
                    phx-value-kind={if kind == :copy, do: "copy", else: "burst"}
                    phx-value-index={i}
                    title="Click to inspect"
                    class={[
                      "relative bg-[#0f0f0f] cursor-zoom-in border",
                      kept? && "border-[#16966a] outline outline-2 outline-[#16966a] -outline-offset-1",
                      !kept? && "border-[#d6d3cc]"
                    ]}
                    style="aspect-ratio: 3 / 2;"
                  >
                    <img
                      src={photo.url}
                      draggable="false"
                      class="w-full h-full object-cover"
                      loading="lazy"
                    />
                    <span class="absolute top-2 left-2 font-mono text-[11px] text-white bg-black/55 px-1.5 py-px">
                      {i + 1}
                    </span>
                    <span class="absolute top-2 right-2 font-sans uppercase tracking-[0.12em] text-[9px] font-bold px-2 py-[5px] border border-white/55 bg-[#111]/70 text-white opacity-90">
                      ⊕ Inspect
                    </span>
                    <%!-- Bottom caption --%>
                    <div class="absolute bottom-0 left-0 right-0 px-2.5 py-2 flex justify-between items-end gap-2"
                         style="background: linear-gradient(transparent, rgba(0,0,0,0.72));">
                      <span class="flex items-center gap-1.5 min-w-0">
                        <%= if kept? do %>
                          <span class="shrink-0 font-sans font-bold text-[8.5px] tracking-[0.18em] text-white bg-[#0f7d55] px-1.5 py-px">
                            ✓ KEEP
                          </span>
                        <% end %>
                        <%= if kind == :copy do %>
                          <% tag = copy_tag(photo.file_path) %>
                          <span class={[
                            "shrink-0 font-sans font-bold text-[8.5px] tracking-[0.16em] text-white px-1.5 py-px",
                            tag == "original" && "bg-[#0f7d55]",
                            tag != "original" && "bg-white/20"
                          ]}>
                            {String.upcase(tag)}
                          </span>
                        <% end %>
                        <span class="font-mono text-[10px] text-white truncate" style="text-shadow: 0 1px 2px #000;">
                          {Path.basename(photo.file_path)}
                        </span>
                      </span>
                      <%= if photo.user_rating do %>
                        <span class="text-white text-[11px] leading-none tracking-[1px] shrink-0">
                          {String.duplicate("★", photo.user_rating)}{String.duplicate("☆", 5 - photo.user_rating)}
                        </span>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Stat footer (4 metrics) --%>
                  <div class="flex gap-3 flex-wrap py-2.5 border-b border-[#e7e5e0]">
                    <%= for {key, label, value} <- [
                      {:sharp, "Sharp", photo.sharpness_score},
                      {:exp, "Expo", photo.exposure_score},
                      {:tech, "Tech", photo.technical_score},
                      {:pref, "Pref", photo.preference_score}
                    ] do %>
                      <% lead? = Map.get(leaders, key) == i %>
                      <div class="flex flex-col gap-1">
                        <span class={[
                          "font-sans uppercase tracking-[0.2em] text-[8px] font-semibold",
                          lead? && "text-[#111]",
                          !lead? && "text-[#a8a8a8]"
                        ]}>
                          {label}<%= if lead?, do: " ▸", else: "" %>
                        </span>
                        <.metric_bar value={value} leader={lead?} />
                      </div>
                    <% end %>
                  </div>

                  <%!-- Action bar (always-visible keep/reject) --%>
                  <div class="flex items-center gap-2 mt-2.5">
                    <div class="flex-1">
                      <.action_bar photo_id={photo.id} keep_active={kept?} size="sm" />
                    </div>
                    <span class="font-mono text-[10px] text-[#a8a8a8] shrink-0">
                      {format_capture_time(photo.captured_at)}
                    </span>
                  </div>
                </div>
              <% end %>

              <%!-- MoreCell — overflow tile for groups with >3 frames --%>
              <%= if overflow? do %>
                <% preview = if keeper_hidden?, do: keeper, else: hd(hidden_photos) %>
                <% inspect_index = if keeper_hidden?, do: keeper_idx, else: 3 %>
                <button
                  phx-click="open_inspector"
                  phx-value-group={group_id}
                  phx-value-kind={if kind == :copy, do: "copy", else: "burst"}
                  phx-value-index={inspect_index}
                  title="Inspect all frames"
                  class="flex flex-col p-0 border-0 bg-transparent cursor-pointer text-left"
                >
                  <div class="relative bg-[#0f0f0f] border border-dashed border-[#d6d3cc] overflow-hidden" style="aspect-ratio: 3 / 2;">
                    <img src={preview.url} draggable="false" class="w-full h-full object-cover opacity-50" />
                    <div class="absolute inset-0 bg-[#111]/45"></div>
                    <div class="absolute top-2 left-0 right-0 text-center font-serif font-bold text-[40px] text-white leading-none"
                         style="text-shadow: 0 2px 8px rgba(0,0,0,0.5);">
                      +{length(hidden_photos)}
                    </div>
                    <div class="absolute left-0 right-0 bottom-3 flex flex-col items-center gap-0">
                      <span class="font-sans uppercase tracking-[0.22em] text-[9.5px] font-semibold text-white">
                        more frame<%= if length(hidden_photos) == 1, do: "", else: "s" %>
                      </span>
                      <%= if keeper_hidden? do %>
                        <span class="mt-1.5 font-sans font-bold text-[8.5px] tracking-[0.16em] text-white bg-[#0f7d55] px-1.5 py-px">
                          ✓ KEEPER INSIDE
                        </span>
                      <% end %>
                    </div>
                  </div>
                  <span class="block text-center font-sans uppercase tracking-[0.16em] text-[10px] font-bold text-[#111] py-2.5 border-b border-[#e7e5e0]">
                    ⊕ Inspect all
                  </span>
                </button>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>

      <%!-- Project filter (suppressed on Bursts/Copies) --%>
      <%= if @projects != [] and @filter not in [:bursts, :copies] do %>
        <div class="flex items-center gap-2 mb-8 flex-wrap">
          <span class="font-sans text-[9px] uppercase tracking-widest text-gray-400 shrink-0">
            Project
          </span>
          <button
            phx-click="set_project_filter"
            phx-value-project=""
            class={[
              "font-sans text-[10px] uppercase tracking-wider px-3 py-1 border transition-colors",
              is_nil(@project_filter) && "border-[#111111] text-[#111111]",
              !is_nil(@project_filter) &&
                "border-gray-200 text-gray-400 hover:border-gray-500 hover:text-gray-700"
            ]}
          >
            all
          </button>
          <%= for proj <- @projects do %>
            <button
              phx-click="set_project_filter"
              phx-value-project={proj}
              class={[
                "font-mono text-[10px] px-3 py-1 border transition-colors",
                @project_filter == proj && "border-[#111111] text-[#111111]",
                @project_filter != proj &&
                  "border-gray-200 text-gray-400 hover:border-gray-500 hover:text-gray-700"
              ]}
            >
              {proj}
            </button>
          <% end %>
        </div>
      <% end %>

      <%!-- Selection toolbar (sticky-feeling, only when there's a selection) --%>
      <%= if MapSet.size(@selected) > 0 do %>
        <div class="sticky top-2 z-10 mb-4 flex flex-col md:flex-row md:items-center gap-3 p-3 border-2 border-[#111111] bg-[#fcfbf9] shadow-sm">
          <p class="font-sans text-xs uppercase tracking-widest text-[#111111] shrink-0">
            {MapSet.size(@selected)} selected
          </p>

          <div class="flex items-center gap-1 flex-wrap">
            <%= for proj <- @projects do %>
              <button
                phx-click="bulk_assign_project"
                phx-value-name={proj}
                class="font-mono text-[10px] px-2 py-1 border border-gray-300 text-gray-700 hover:border-[#111111] hover:text-[#111111] transition-colors"
              >
                {proj}
              </button>
            <% end %>
          </div>

          <form phx-submit="bulk_assign_input" class="flex gap-1 flex-1 min-w-[180px]">
            <input
              type="text"
              name="value"
              value={@bulk_project}
              phx-change="bulk_project_input"
              phx-debounce="200"
              placeholder="new project name…"
              class="flex-1 bg-transparent border border-gray-300 focus:border-[#111111] px-2 py-1 font-mono text-xs text-[#111111] placeholder-gray-400 focus:outline-none"
            />
            <button
              type="submit"
              class="font-sans text-[10px] uppercase tracking-widest text-gray-700 border border-gray-300 hover:border-[#111111] hover:text-[#111111] px-2 py-1 transition-colors"
            >
              Assign
            </button>
          </form>

          <button
            phx-click="bulk_reject"
            data-confirm={"Reject #{MapSet.size(@selected)} photos? (reversible)"}
            class="font-sans text-[10px] uppercase tracking-widest text-red-700 border border-red-300 hover:border-red-600 px-3 py-1 transition-colors shrink-0"
          >
            Reject
          </button>
          <button
            phx-click="select_all"
            class="font-sans text-[10px] uppercase tracking-widest text-gray-500 border border-gray-300 hover:border-gray-700 hover:text-gray-700 px-3 py-1 transition-colors shrink-0"
          >
            Select page
          </button>
          <button
            phx-click="clear_selection"
            class="font-sans text-[10px] uppercase tracking-widest text-gray-500 hover:text-[#111111] transition-colors shrink-0"
          >
            Clear
          </button>
        </div>
      <% end %>

      <%= if @filter not in [:bursts, :copies] do %>
        <%!-- Keyboard hint --%>
        <p class="mb-4 font-sans text-[9px] uppercase tracking-widest text-gray-300">
          Click a photo, then: <span class="text-gray-400">1–5</span>
          rate · <span class="text-gray-400">p</span>
          pick · <span class="text-gray-400">x</span>
          reject · <span class="text-gray-400">m</span>
          select · or use <.link navigate={~p"/review"} class="text-gray-500 underline">Review</.link>
          for single-image culling
        </p>

        <%!-- Gallery Grid --%>
        <%= if @photos == [] do %>
          <div class="text-center py-24 text-gray-400 font-serif italic text-xl">
            <%= cond do %>
              <% @total == 0 -> %>
                No photos yet.
                <.link navigate={~p"/"} class="border-b border-gray-400">
                  Ingest from a directory.
                </.link>
              <% @search != "" -> %>
                No photos match "{@search}".
              <% true -> %>
                No photos match this filter.
            <% end %>
          </div>
        <% else %>
          <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
            <%= for photo <- @photos do %>
              <% vibe = Photos.vibe_score(photo, @tag_profile) %>
              <% selected? = MapSet.member?(@selected, photo.id) %>
              <div
                class={[
                  "group relative aspect-square overflow-hidden border bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-1",
                  selected? && "border-[#111111] ring-2 ring-[#111111]",
                  !selected? && "border-gray-200 focus:ring-[#111111]"
                ]}
                tabindex="0"
                phx-keydown="photo_keydown"
                phx-value-id={photo.id}
              >
                <%!-- Selection checkbox (bottom-left, out of the way of hover overlay's delete + top-right badges) --%>
                <button
                  phx-click="toggle_select"
                  phx-value-id={photo.id}
                  title="select (m)"
                  class={[
                    "absolute bottom-2 left-2 z-20 w-6 h-6 flex items-center justify-center font-sans text-sm font-bold transition-all",
                    selected? && "bg-[#111111] text-[#fcfbf9] border-2 border-[#111111]",
                    !selected? &&
                      "bg-[#fcfbf9]/90 text-transparent border-2 border-gray-300 opacity-0 group-hover:opacity-100 hover:border-[#111111] hover:text-gray-500"
                  ]}
                >
                  ✓
                </button>
                <%= if photo.url do %>
                  <img
                    src={photo.url}
                    alt={photo.subject || "Photo"}
                    class="object-cover w-full h-full transition-transform duration-500 group-hover:scale-105"
                  />
                <% else %>
                  <div class="w-full h-full flex flex-col items-center justify-center gap-2 bg-gray-100">
                    <span class="text-red-400 font-sans text-lg">✗</span>
                    <span class="font-mono text-[9px] text-gray-400 text-center px-2 leading-snug truncate w-full text-center">
                      {Path.basename(photo.file_path || "")}
                    </span>
                  </div>
                <% end %>

                <%!-- Primary score — top-left --%>
                <% primary = vibe || photo.preference_score %>
                <%= if primary do %>
                  <div class={[
                    "absolute top-2 left-2 font-sans text-[11px] font-bold tabular-nums px-2 py-1",
                    primary >= 70 && "bg-[#111111] text-[#fcfbf9]",
                    (primary >= 40 and primary < 70) &&
                      "bg-[#fcfbf9]/90 text-gray-600 border border-gray-300",
                    primary < 40 && "bg-[#fcfbf9]/70 text-gray-400 border border-gray-200"
                  ]}>
                    {primary}
                  </div>
                <% end %>

                <%!-- Match status + project — top-right --%>
                <div class="absolute top-2 right-2 flex flex-col items-end gap-1">
                  <%= cond do %>
                    <% photo.manual_match -> %>
                      <div class="bg-amber-400 text-[#111111] font-sans text-[10px] font-bold uppercase tracking-wider px-2 py-1">
                        ★ Pick
                      </div>
                    <% photo.preference_score != nil and photo.preference_score >= @match_threshold -> %>
                      <div class="bg-[#111111] text-[#fcfbf9] font-sans text-[10px] font-bold uppercase tracking-wider px-2 py-1">
                        ✓ Match
                      </div>
                    <% true -> %>
                  <% end %>
                  <%= if photo.project do %>
                    <div class="bg-[#fcfbf9]/90 border border-gray-300 font-sans text-[9px] uppercase tracking-wider px-2 py-0.5 text-gray-500 max-w-[80px] truncate">
                      {photo.project}
                    </div>
                  <% end %>
                </div>

                <%!-- Hover overlay — failed variant --%>
                <%= cond do %>
                  <% photo.curation_status == "failed" -> %>
                    <div class="absolute inset-0 bg-[#111111]/85 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity duration-300 flex flex-col justify-center items-center gap-3 p-4">
                      <p class="font-sans text-[10px] uppercase tracking-widest text-red-400 text-center">
                        Curation failed
                      </p>
                      <%= if photo.failure_reason && photo.failure_reason != "" do %>
                        <p class="font-mono text-[9px] text-gray-400 text-center leading-snug px-2 truncate w-full">
                          {photo.failure_reason}
                        </p>
                      <% end %>
                      <button
                        phx-click="retry_photo"
                        phx-value-id={photo.id}
                        class="font-sans text-[10px] uppercase tracking-widest text-[#fcfbf9] border border-gray-500 hover:border-white px-4 py-2 transition-colors"
                      >
                        Retry
                      </button>
                      <button
                        phx-click="delete_photo"
                        phx-value-id={photo.id}
                        data-confirm="Remove this photo?"
                        class="font-sans text-[9px] uppercase tracking-widest text-gray-600 hover:text-red-400 transition-colors"
                      >
                        discard
                      </button>
                    </div>
                  <% photo.curation_status == "rejected" -> %>
                    <div class="absolute inset-0 bg-[#111111]/85 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity duration-300 flex flex-col justify-center items-center gap-3 p-4">
                      <p class="font-sans text-[10px] uppercase tracking-widest text-red-400 text-center">
                        Rejected
                      </p>
                      <p class="font-mono text-[9px] text-gray-500 text-center leading-snug px-2 truncate w-full">
                        {Path.basename(photo.file_path || "")}
                      </p>
                      <button
                        phx-click="restore_photo"
                        phx-value-id={photo.id}
                        class="font-sans text-[10px] uppercase tracking-widest text-[#fcfbf9] border border-gray-500 hover:border-white px-4 py-2 transition-colors"
                      >
                        Restore
                      </button>
                      <button
                        phx-click="delete_photo"
                        phx-value-id={photo.id}
                        data-confirm="Hard-delete this photo (file + row)?"
                        class="font-sans text-[9px] uppercase tracking-widest text-gray-600 hover:text-red-400 transition-colors"
                      >
                        delete forever
                      </button>
                    </div>
                  <% true -> %>
                    <%!-- Hover overlay — normal variant --%>
                    <div class="absolute inset-0 bg-[#111111]/80 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity duration-300 flex flex-col justify-end p-4">
                      <button
                        phx-click="delete_photo"
                        phx-value-id={photo.id}
                        data-confirm="Remove this photo from the archive?"
                        class="absolute top-2 left-2 font-sans text-[9px] uppercase tracking-widest text-gray-600 hover:text-red-400 border border-gray-800 hover:border-red-600 px-2 py-1 transition-colors"
                      >
                        delete
                      </button>

                      <p class="text-[#fcfbf9] font-serif text-sm leading-snug mb-1">
                        {photo.subject}
                      </p>

                      <%!-- Score breakdown --%>
                      <div class="flex items-center gap-1.5 mt-1 mb-1 flex-wrap">
                        <%= if vibe do %>
                          <span class="font-sans text-[9px] uppercase tracking-wider text-gray-400 border border-gray-700 px-1.5 py-0.5">
                            vibe {vibe}
                          </span>
                        <% end %>
                        <%= if photo.preference_score do %>
                          <span class="font-sans text-[9px] uppercase tracking-wider text-gray-400 border border-gray-700 px-1.5 py-0.5">
                            pref {photo.preference_score}
                          </span>
                        <% end %>
                        <%= if photo.technical_score do %>
                          <span class="font-sans text-[9px] uppercase tracking-wider text-gray-400 border border-gray-700 px-1.5 py-0.5">
                            tech {photo.technical_score}
                          </span>
                        <% end %>
                        <%= if photo.content_type do %>
                          <span class="font-sans text-[9px] uppercase tracking-wider text-gray-500">
                            {photo.content_type}
                          </span>
                        <% end %>
                      </div>

                      <div class="flex flex-wrap gap-1 mt-1">
                        <%= for tag <- photo.suggested_tags do %>
                          <button
                            phx-click="delete_tag"
                            phx-value-id={photo.id}
                            phx-value-tag={tag}
                            class="group/tag font-sans text-[10px] uppercase tracking-wider border border-gray-600 text-gray-400 px-1.5 py-0.5 hover:border-red-500 hover:text-red-400 transition-colors flex items-center gap-1"
                          >
                            {String.downcase(tag)}<span class="opacity-0 group-hover/tag:opacity-100 transition-opacity leading-none">×</span>
                          </button>
                        <% end %>
                        <input
                          type="text"
                          placeholder="+ tag"
                          maxlength="30"
                          phx-keyup="add_tag"
                          phx-key="Enter"
                          phx-value-id={photo.id}
                          name="tag"
                          class="font-sans text-[10px] uppercase tracking-wider border border-gray-700 border-dashed text-gray-500 bg-transparent px-1.5 py-0.5 w-16 focus:outline-none focus:border-gray-400 focus:text-gray-300 placeholder-gray-700"
                        />
                      </div>

                      <div class="flex items-center justify-between mt-3">
                        <div class="flex gap-1">
                          <%= for star <- 1..5 do %>
                            <button
                              phx-click="rate"
                              phx-value-id={photo.id}
                              phx-value-rating={star}
                              class={[
                                "text-lg leading-none transition-colors",
                                photo.user_rating && photo.user_rating >= star && "text-[#fcfbf9]",
                                !(photo.user_rating && photo.user_rating >= star) &&
                                  "text-gray-600 hover:text-gray-300"
                              ]}
                            >
                              ★
                            </button>
                          <% end %>
                        </div>
                        <button
                          phx-click="toggle_match"
                          phx-value-id={photo.id}
                          title="Chef's pick — manual override, independent of the preference score"
                          class={[
                            "font-sans text-[10px] uppercase tracking-widest px-2 py-1 transition-colors",
                            photo.manual_match &&
                              "bg-amber-400 text-[#111111] border border-amber-400 hover:bg-amber-300",
                            !photo.manual_match &&
                              "text-gray-500 border border-gray-700 hover:border-amber-400 hover:text-amber-300"
                          ]}
                        >
                          {if photo.manual_match, do: "★ picked", else: "☆ pick"}
                        </button>
                      </div>

                      <form phx-submit="set_project" class="mt-2 flex gap-1">
                        <input type="hidden" name="_id" value={photo.id} />
                        <input
                          type="text"
                          name="project"
                          value={photo.project || ""}
                          placeholder="project..."
                          class="flex-1 bg-transparent border-b border-gray-600 text-gray-300 font-sans text-xs px-1 py-0.5 focus:outline-none focus:border-gray-300 placeholder-gray-600"
                        />
                        <button
                          type="submit"
                          class="text-gray-500 hover:text-gray-200 font-sans text-xs px-1 uppercase tracking-wider"
                        >
                          set
                        </button>
                      </form>
                    </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Pagination --%>
          <%= if @pages > 1 do %>
            <div class="mt-12 flex items-center justify-center gap-2 font-sans text-xs uppercase tracking-widest">
              <%= if @page > 1 do %>
                <button
                  phx-click="page"
                  phx-value-n={@page - 1}
                  class="border border-gray-300 px-4 py-2 hover:border-[#111111] transition-colors"
                >
                  ← Prev
                </button>
              <% end %>
              <span class="px-4 py-2 text-gray-400">
                {@page} / {@pages}
              </span>
              <%= if @page < @pages do %>
                <button
                  phx-click="page"
                  phx-value-n={@page + 1}
                  class="border border-gray-300 px-4 py-2 hover:border-[#111111] transition-colors"
                >
                  Next →
                </button>
              <% end %>
            </div>
          <% end %>
        <% end %>
      <% end %>
      <%!-- /if @filter not in [:bursts, :copies] --%>

      <%!-- Inspector overlay (Direction C) — focus layer for a single group.

           Colocated JS hooks below are extracted at compile time by
           Phoenix.LiveView.ColocatedHook and bundled via the
           `phoenix-colocated/orchestrator` import in app.js. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LoupeStage">
        export default {
          mounted() {
            this.loupe = document.getElementById("inspector-loupe");
            this.badge = document.getElementById("inspector-zoom-badge");
            const size = 190;
            this.handleMove = (e) => {
              if (!this.loupe) return;
              const rect = this.el.getBoundingClientRect();
              const x = e.clientX - rect.left;
              const y = e.clientY - rect.top;
              const fx = (x / rect.width) * 100;
              const fy = (y / rect.height) * 100;
              const url = this.el.dataset.activeUrl;
              const zoom = parseFloat(this.el.dataset.zoom || "2.6");
              const loupeX = Math.max(6, Math.min(x - size/2, rect.width - size - 6));
              const loupeY = Math.max(6, y - size - 16);
              this.loupe.style.left = loupeX + "px";
              this.loupe.style.top = loupeY + "px";
              this.loupe.style.backgroundImage = url ? `url("${url}")` : "none";
              this.loupe.style.backgroundSize = (zoom * 100) + "%";
              this.loupe.style.backgroundPosition = fx + "% " + fy + "%";
              this.loupe.style.opacity = 1;
              if (this.badge) this.badge.style.opacity = 1;
            };
            this.handleLeave = () => {
              if (this.loupe) this.loupe.style.opacity = 0;
              if (this.badge) this.badge.style.opacity = 0;
            };
            this.el.addEventListener("mousemove", this.handleMove);
            this.el.addEventListener("mouseleave", this.handleLeave);
          },
          destroyed() {
            this.el.removeEventListener("mousemove", this.handleMove);
            this.el.removeEventListener("mouseleave", this.handleLeave);
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".InspectorKeys">
        export default {
          mounted() {
            this.handleKey = (e) => {
              const tag = (e.target.tagName || "").toLowerCase();
              if (tag === "input" || tag === "textarea") return;
              switch (e.key) {
                case "Escape":
                  this.pushEvent("close_inspector"); break;
                case "ArrowRight":
                  e.preventDefault(); this.pushEvent("cycle", {dir: "next"}); break;
                case "ArrowLeft":
                  e.preventDefault(); this.pushEvent("cycle", {dir: "prev"}); break;
                case " ":
                case "f":
                case "F":
                  e.preventDefault(); this.pushEvent("flip"); break;
                case "k":
                case "K":
                  this.pushEvent("inspector_keep"); break;
                case "x":
                case "X":
                  this.pushEvent("inspector_reject"); break;
              }
            };
            // Capture-phase click handler so we can intercept shift-click on
            // filmstrip thumbs before LiveView fires the plain set_active.
            this.handleShiftClick = (e) => {
              if (!e.shiftKey) return;
              const thumb = e.target.closest(".inspector-thumb");
              if (!thumb) return;
              e.preventDefault();
              e.stopImmediatePropagation();
              const idx = parseInt(thumb.dataset.index, 10);
              this.pushEvent("toggle_compare", {index: idx});
            };
            window.addEventListener("keydown", this.handleKey);
            this.el.addEventListener("click", this.handleShiftClick, true);
          },
          destroyed() {
            window.removeEventListener("keydown", this.handleKey);
            this.el.removeEventListener("click", this.handleShiftClick, true);
          }
        }
      </script>
      <%= if @inspect_state do %>
        <% st = @inspect_state %>
        <% frames = inspector_frames_for_render(assigns, st) %>
        <% n = length(frames) %>
        <% f = Enum.at(frames, st.active) %>
        <% other_idx =
          cond do
            is_integer(st.compare) and st.compare != st.active -> st.compare
            true -> rem(st.active + 1, max(n, 1))
          end %>
        <% other = Enum.at(frames, other_idx) %>
        <% group_id = st.group_id %>
        <% kind = st.kind %>
        <% reason = survey_reason(kind, frames) %>
        <% group_date = case f do
          %{captured_at: dt} -> format_group_date(dt)
          _ -> "—"
        end %>

        <div
          id="inspector-scrim"
          phx-hook=".InspectorKeys"
          class="fixed inset-0 z-50 flex items-center justify-center p-6 bg-[rgba(20,18,14,0.62)]"
          style="backdrop-filter: blur(3px);"
        >
          <div
            phx-click-away="close_inspector"
            class="bg-[#fcfbf9] border border-[#111] flex flex-col overflow-hidden"
            style="width: min(1240px, 96vw); height: min(860px, 94vh); box-shadow: 0 30px 90px rgba(0,0,0,0.4);"
          >
            <%!-- Header --%>
            <div class="flex items-center justify-between px-5 py-3.5 border-b-2 border-[#111] bg-white shrink-0">
              <div class="flex items-baseline gap-3.5 min-w-0">
                <span class="font-sans font-black text-[16px] tracking-tight">
                  {inspector_kind_word(kind)} {String.pad_leading("#{group_id}", 2, "0")}
                </span>
                <span class="font-mono text-[12px] text-[#a8a8a8] truncate">
                  {n} frames<%= if group_date != "—", do: " · #{group_date}" %>
                </span>
              </div>
              <div class="flex items-center gap-2.5 shrink-0">
                <span class="font-serif italic text-[13px] text-[#7a7a7a] mr-1 hidden md:inline">
                  ← → flip · Space toggle · K keep · X reject · Esc close
                </span>
                <.ghost_btn strong phx-click="close_inspector">✕ Close</.ghost_btn>
              </div>
            </div>

            <div class="flex flex-1 min-h-0">
              <%!-- Stage column --%>
              <div class="flex-1 min-w-0 flex flex-col px-5 py-4 overflow-y-auto">
                <div
                  id="inspector-stage"
                  phx-hook=".LoupeStage"
                  data-active-url={(f && f.url) || ""}
                  data-zoom={st.zoom}
                  class="relative flex-1 min-h-[260px] bg-[#0d0d0d] border border-[#d6d3cc] overflow-hidden cursor-crosshair"
                >
                  <%= for {fr, i} <- Enum.with_index(frames) do %>
                    <img
                      src={fr.url}
                      draggable="false"
                      class="absolute inset-0 w-full h-full object-contain"
                      style={"opacity: #{if i == st.active, do: 1, else: 0}; transition: opacity .1s;"}
                    />
                  <% end %>

                  <%!-- Active frame badge --%>
                  <div class="absolute top-3 left-3 flex items-center gap-2.5 bg-[#111]/80 px-3 py-1.5 z-10">
                    <span class="font-sans uppercase tracking-[0.24em] text-[9px] font-semibold text-white">
                      Frame {st.active + 1}
                    </span>
                    <%= if f do %>
                      <span class="font-mono text-[11px] text-[#d6d6d6] truncate max-w-[260px]">
                        {Path.basename(f.file_path)}
                      </span>
                    <% end %>
                  </div>

                  <%!-- A/B compare flag --%>
                  <%= if is_integer(st.compare) do %>
                    <div class="absolute top-3 right-3 bg-[#b94900] px-2.5 py-1.5 z-10">
                      <span class="font-sans uppercase tracking-[0.2em] text-[9px] font-semibold text-white">
                        A/B · {st.active + 1} ⇄ {st.compare + 1}
                      </span>
                    </div>
                  <% end %>

                  <%!-- Loupe (positioned + styled by the LoupeStage hook) --%>
                  <div
                    id="inspector-loupe"
                    class="pointer-events-none absolute rounded-full border-2 border-white opacity-0 z-20"
                    style="width: 190px; height: 190px; box-shadow: 0 8px 30px rgba(0,0,0,0.5); background-repeat: no-repeat;"
                  ></div>
                  <%!-- Zoom badge — corner-pinned to the stage so it stays
                       readable regardless of where the loupe is. --%>
                  <div
                    id="inspector-zoom-badge"
                    class="absolute bottom-3 right-3 z-10 opacity-0 transition-opacity duration-100 font-mono text-[10px] text-white bg-[#111]/80 px-2 py-1"
                  >
                    {:erlang.float_to_binary(st.zoom * 1.0, decimals: 1)}×
                  </div>
                </div>

                <%!-- Controls under stage --%>
                <div class="flex items-center gap-3 mt-3 flex-wrap">
                  <button
                    phx-click="flip"
                    class="font-sans uppercase tracking-[0.16em] text-[11px] font-bold px-4 py-2 border border-[#111] bg-white text-[#111] cursor-pointer"
                  >
                    ⟲ Flip
                  </button>
                  <div class="flex items-center gap-1.5">
                    <span class="font-sans uppercase tracking-[0.2em] text-[9px] font-semibold text-[#7a7a7a]">
                      Zoom
                    </span>
                    <%= for z <- [2.0, 2.6, 4.0] do %>
                      <button
                        phx-click="set_zoom"
                        phx-value-zoom={z}
                        class={[
                          "font-mono text-[11px] px-2 py-1 border border-[#d6d3cc] cursor-pointer",
                          st.zoom == z && "bg-[#111] text-[#fcfbf9]",
                          st.zoom != z && "bg-white text-[#111]"
                        ]}
                      >
                        {:erlang.float_to_binary(z, decimals: 1)}×
                      </button>
                    <% end %>
                  </div>
                  <div class="flex-1"></div>
                  <%= if f do %>
                    <div class="shrink-0 w-[230px]">
                      <.action_bar photo_id={f.id} />
                    </div>
                  <% end %>
                </div>

                <%!-- Filmstrip --%>
                <div class="flex gap-2 mt-3.5 overflow-x-auto pb-1">
                  <%= for {fr, i} <- Enum.with_index(frames) do %>
                    <% active? = i == st.active %>
                    <% compare? = i == st.compare %>
                    <% keeper? = i == 0 %>
                    <button
                      phx-click="set_active"
                      phx-value-index={i}
                      title={if(keeper?, do: "suggested keeper · ", else: "") <> "click to view · shift-click to pin A/B"}
                      data-index={i}
                      class={[
                        "relative p-0 border-2 bg-[#0f0f0f] cursor-pointer shrink-0 inspector-thumb",
                        active? && "border-[#111]",
                        !active? and compare? && "border-[#b94900]",
                        !active? and !compare? && "border-[#d6d3cc]"
                      ]}
                    >
                      <img
                        src={fr.url}
                        draggable="false"
                        class={[
                          "block object-cover",
                          active? && "opacity-100",
                          !active? && "opacity-70"
                        ]}
                        style="width: 84px; height: 56px;"
                      />
                      <span class="absolute top-0.5 left-0.5 font-mono text-[9px] text-white bg-black/60 px-1">
                        {i + 1}
                      </span>
                      <%= if keeper? do %>
                        <span class="absolute top-0.5 right-0.5 w-[7px] h-[7px] bg-[#0f7d55] rounded-full"></span>
                      <% end %>
                    </button>
                  <% end %>
                </div>
              </div>

              <%!-- Right ledger --%>
              <div class="w-[320px] shrink-0 border-l border-[#d6d3cc] bg-[#fcfbf9] px-4.5 py-4 flex flex-col overflow-y-auto" style="padding-left: 18px; padding-right: 18px;">
                <span class="font-sans uppercase tracking-[0.28em] text-[9px] font-semibold text-[#7a7a7a] mb-3 block">
                  <%= if is_integer(st.compare), do: "A / B", else: "Active vs keeper" %>
                </span>

                <%!-- Two-column compare header --%>
                <div class="flex border-t-2 border-[#111] border-b border-[#e7e5e0]">
                  <div class="flex-1 py-2 text-center bg-[#eaf4ee]/30">
                    <span class="font-sans uppercase tracking-[0.2em] text-[9px] font-semibold text-[#111]">
                      Active · {st.active + 1}
                    </span>
                  </div>
                  <div class="flex-1 py-2 text-center border-l border-[#e7e5e0]">
                    <span class="font-sans uppercase tracking-[0.2em] text-[9px] font-semibold text-[#7a7a7a]">
                      vs · {other_idx + 1}
                    </span>
                  </div>
                </div>

                <% rows =
                  for {key, label, short} <- [
                        {:sharpness_score, "Sharpness", "Sharp"},
                        {:exposure_score, "Exposure", "Expo"},
                        {:technical_score, "Technical", "Tech"},
                        {:preference_score, "Preference", "Pref"}
                      ] do
                    av = f && Map.get(f, key)
                    bv = other && Map.get(other, key)

                    %{
                      key: key,
                      label: label,
                      short: short,
                      av: av,
                      bv: bv,
                      delta: if(is_integer(av) and is_integer(bv), do: av - bv, else: nil),
                      tied?: is_integer(av) and is_integer(bv) and av == bv,
                      a_lead: is_integer(av) and (is_nil(bv) or av > bv),
                      b_lead: is_integer(bv) and (is_nil(av) or bv > av)
                    }
                  end %>
                <% ties = Enum.filter(rows, & &1.tied?) %>
                <% diffs = Enum.reject(rows, & &1.tied?) %>

                <%!-- Compact tie summary — only when ≥2 metrics agree, otherwise
                     a single "tie" is just rendered inline below. --%>
                <%= if length(ties) >= 2 do %>
                  <div class="flex justify-between items-baseline py-2.5 border-b border-[#e7e5e0]">
                    <span class="font-sans uppercase tracking-[0.2em] text-[8.5px] font-semibold text-[#7a7a7a]">
                      {ties |> Enum.map(& &1.short) |> Enum.join("/")} tied
                    </span>
                    <span class="font-mono text-[10px] text-[#b94900]">
                      at {ties |> Enum.map(& &1.av) |> Enum.uniq() |> Enum.join("/")}
                    </span>
                  </div>
                <% end %>

                <%!-- Differing metrics — full comparison bars --%>
                <%= for row <- if(length(ties) >= 2, do: diffs, else: rows) do %>
                  <div class="py-2.5 border-b border-[#e7e5e0]">
                    <div class="flex justify-between mb-1">
                      <span class="font-sans uppercase tracking-[0.2em] text-[8.5px] font-semibold text-[#7a7a7a]">
                        {row.label}
                      </span>
                      <%= cond do %>
                        <% row.delta == 0 -> %>
                          <span class="font-mono text-[9.5px] text-[#b94900]">tie</span>
                        <% is_integer(row.delta) -> %>
                          <span class="font-mono text-[9.5px] text-[#7a7a7a]">
                            Δ {if row.delta > 0, do: "+", else: ""}{row.delta}
                          </span>
                        <% true -> %>
                      <% end %>
                    </div>
                    <div class="flex gap-2.5">
                      <.metric_bar value={row.av} leader={row.a_lead} compact />
                      <.metric_bar value={row.bv} leader={row.b_lead} compact />
                    </div>
                  </div>
                <% end %>

                <%!-- Rating + time row --%>
                <div class="flex gap-2.5 py-2.5 border-b border-[#e7e5e0]">
                  <div class="flex-1 text-[#111] text-[12px] leading-none tracking-[1px]">
                    <%= if f && f.user_rating, do: String.duplicate("★", f.user_rating) <> String.duplicate("☆", 5 - f.user_rating), else: "☆☆☆☆☆" %>
                  </div>
                  <div class="flex-1 text-[#111] text-[12px] leading-none tracking-[1px]">
                    <%= if other && other.user_rating, do: String.duplicate("★", other.user_rating) <> String.duplicate("☆", 5 - other.user_rating), else: "☆☆☆☆☆" %>
                  </div>
                </div>
                <div class="flex gap-2.5 py-2.5">
                  <div class="flex-1 font-mono text-[11px] text-[#7a7a7a]">
                    {f && format_capture_time(f.captured_at)}
                  </div>
                  <div class="flex-1 font-mono text-[11px] text-[#7a7a7a]">
                    {other && format_capture_time(other.captured_at)}
                  </div>
                </div>

                <%!-- Reason + tip --%>
                <div class="mt-auto pt-3">
                  <.reason_chip reason={reason} class="w-full box-border" />
                  <p class="font-serif text-[12.5px] text-[#7a7a7a] leading-relaxed mt-3">
                    <b class="text-[#111]">Shift-click</b>
                    any thumbnail to pin it as the A/B partner, then
                    <b class="text-[#111]">Flip</b>
                    to toggle between just those two.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper used by the Inspector overlay's HEEx — resolves the active group's
  # frames from socket assigns. Inlined here so the template stays declarative.
  defp inspector_frames_for_render(%{burst_groups: groups}, %{kind: :burst, group_id: gid}) do
    case List.keyfind(groups, gid, 0) do
      {^gid, photos} -> photos
      _ -> []
    end
  end

  defp inspector_frames_for_render(%{dup_groups: groups}, %{kind: :copy, group_id: gid}) do
    case List.keyfind(groups, gid, 0) do
      {^gid, photos} -> photos
      _ -> []
    end
  end

  defp inspector_frames_for_render(_assigns, _st), do: []
end
