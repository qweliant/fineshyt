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
      |> assign(:match_threshold, @match_threshold)
      |> load_photos()

    {:ok, socket}
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp query_opts(socket) do
    [
      filter:  socket.assigns.filter,
      sort:    socket.assigns.sort,
      search:  socket.assigns.search,
      page:    socket.assigns.page,
      project: socket.assigns.project_filter
    ]
  end

  defp load_photos(socket) do
    opts = query_opts(socket)

    if socket.assigns.sort == :vibe_desc do
      # Vibe is computed in-memory from the tag profile, so we fetch all
      # matching photos, score + sort here, then slice the page.
      profile = socket.assigns.tag_profile
      all = Photos.list_photos(Keyword.merge(opts, page: :all, sort: :newest))

      sorted =
        Enum.sort_by(all, fn photo ->
          {Photos.vibe_score(photo, profile) || -1, photo.preference_score || -1}
        end, :desc)

      total = length(sorted)
      pages = max(1, ceil(total / Photos.page_size()))

      page_photos =
        sorted
        |> Enum.drop((socket.assigns.page - 1) * Photos.page_size())
        |> Enum.take(Photos.page_size())

      assign(socket, photos: page_photos, total: total, pages: pages)
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
    atom = case filter do
      "match"        -> :match
      "no_match"     -> :no_match
      "rated"        -> :rated
      "unrated"      -> :unrated
      "failed"       -> :failed
      "rejected"     -> :rejected
      "for_projects" -> :for_projects
      "bursts"       -> :bursts
      _              -> :all
    end

    socket = socket |> assign(:selected, MapSet.new())

    socket =
      if atom == :bursts do
        assign(socket, :burst_groups, Photos.list_burst_groups())
      else
        socket
      end

    {:noreply, reload(socket, filter: atom)}
  end

  @impl Phoenix.LiveView
  def handle_event("set_sort", %{"sort" => sort}, socket) do
    atom = case sort do
      "vibe_desc"       -> :vibe_desc
      "rating_desc"     -> :rating_desc
      "preference_desc" -> :preference_desc
      "preference_asc"  -> :preference_asc
      _                 -> :newest
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
      {:ok, _}    -> {:noreply, load_photos(socket)}
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
    {:noreply, socket
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
    {:noreply, socket |> put_flash(:info, "Re-queued #{length(failed)} failed photos.") |> load_photos()}
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
    if name == "", do: {:noreply, socket}, else: handle_event("bulk_assign_project", %{"name" => name}, socket)
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
        if missing > 0, do: " (#{missing} file#{if missing == 1, do: "", else: "s"} were already gone)", else: ""

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
         |> put_flash(:info, "Kept sharpest, rejected #{n} duplicate#{if n == 1, do: "", else: "s"}.")
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
       |> put_flash(:info, "Kept sharpest per burst, rejected #{n} duplicate#{if n == 1, do: "", else: "s"}.")
       |> load_photos()}
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
    {:noreply, socket
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
     |> put_flash(:info, "Detected #{n_groups} burst group#{if n_groups == 1, do: "", else: "s"}.")
     |> load_photos()}
  end

  def handle_info({:curation_failed, _ref, _basename, _reason}, socket) do
    # Reload so failed tab count stays fresh
    {:noreply, load_photos(socket)}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  # ── render ────────────────────────────────────────────────────────────────

  @doc """
  Render the gallery grid.

  Light theme matching the FINE.SHYT serif aesthetic. Header carries the
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
          <h1 class="text-6xl md:text-8xl font-black tracking-tight leading-none">FINE.<br/>SHYT.</h1>
          <p class="mt-4 text-lg font-light italic text-gray-600">
            The Archive. <span class="font-sans text-sm not-italic text-gray-400"><%= @total %> photos</span>
          </p>
        </div>
        <div class="mt-6 md:mt-0 font-sans uppercase tracking-widest text-xs flex gap-6">
          <.link navigate={~p"/review"} class="border-b border-[#111111] pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors">
            Review →
          </.link>
          <.link navigate={~p"/projects"} class="border-b border-gray-400 pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors">
            Projects
          </.link>
          <.link navigate={~p"/"} class="border-b border-gray-400 pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors">
            ← Ingest
          </.link>
        </div>
      </header>

      <%!-- Search + Sort bar --%>
      <div class="flex flex-col sm:flex-row gap-4 mb-8">
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
            <button type="button" phx-click="search" phx-value-q="" class="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-700 font-sans text-sm">×</button>
          <% end %>
        </form>
        <form phx-change="set_sort">
          <select
            name="sort"
            class="border border-gray-300 bg-[#fcfbf9] px-4 py-2.5 font-sans text-xs uppercase tracking-widest focus:outline-none focus:border-[#111111] cursor-pointer"
          >
            <option value="vibe_desc"        selected={@sort == :vibe_desc}>Vibe ↓</option>
            <option value="newest"           selected={@sort == :newest}>Newest</option>
            <option value="preference_desc"  selected={@sort == :preference_desc}>Preference ↓</option>
            <option value="preference_asc"   selected={@sort == :preference_asc}>Preference ↑</option>
            <option value="rating_desc"      selected={@sort == :rating_desc}>Rating ↓</option>
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
          {"Rejected", :rejected}, {"Failed", :failed}
        ] do %>
          <button
            phx-click="set_filter"
            phx-value-filter={value}
            class={[
              "font-sans uppercase tracking-widest text-xs px-5 py-3 border-b-2 transition-colors whitespace-nowrap shrink-0",
              @filter == value and value in [:failed, :rejected] && "border-red-600 text-red-600",
              @filter == value and value not in [:failed, :rejected] && "border-[#111111] text-[#111111]",
              @filter != value and value in [:failed, :rejected] && "border-transparent text-red-300 hover:text-red-500",
              @filter != value and value not in [:failed, :rejected] && "border-transparent text-gray-400 hover:text-gray-600"
            ]}
          >
            <%= label %>
          </button>
        <% end %>
      </div>

      <%!-- Rejected tab actions --%>
      <%= if @filter == :rejected and @total > 0 do %>
        <div class="flex items-center gap-4 mb-6 p-3 border border-red-200 bg-red-50/50">
          <p class="font-sans text-xs text-red-600 flex-1">
            <%= @total %> photo<%= if @total != 1, do: "s" %> in trash. Click <span class="font-bold">restore</span> to bring one back, or <span class="font-bold">empty trash</span> to hard-delete the files.
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
            <%= @total %> photo<%= if @total != 1, do: "s" %> failed AI curation (timeout or service error).
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

      <%!-- Burst view --%>
      <%= if @filter == :bursts do %>
        <div class="mb-6 p-4 border border-purple-200 bg-purple-50/30">
          <div class="flex items-center gap-4 mb-4">
            <p class="font-sans text-xs text-purple-700 flex-1">
              <%= if @burst_groups == [] do %>
                No burst groups detected yet. Click <span class="font-bold">Detect Bursts</span> to scan for visually similar photo sequences.
              <% else %>
                <%= length(@burst_groups) %> burst group<%= if length(@burst_groups) != 1, do: "s" %> found.
                The sharpest frame in each group is shown first.
              <% end %>
            </p>
            <button
              phx-click="detect_bursts"
              class="font-sans text-[10px] uppercase tracking-widest text-purple-700 border border-purple-300 px-3 py-1.5 hover:border-purple-600 transition-colors shrink-0"
            >
              Detect Bursts
            </button>
            <%= if @burst_groups != [] do %>
              <button
                phx-click="keep_best_all"
                data-confirm={"Keep sharpest in all #{length(@burst_groups)} groups, reject the rest?"}
                class="font-sans text-[10px] uppercase tracking-widest text-[#111111] border border-[#111111] px-3 py-1.5 hover:bg-[#111111] hover:text-[#fcfbf9] transition-colors shrink-0"
              >
                Keep Best All
              </button>
            <% end %>
          </div>

          <%= for {group_id, photos} <- @burst_groups do %>
            <% [best | rest] = photos %>
            <div class="mb-6 border border-gray-200 bg-white/70 p-3">
              <div class="flex items-center justify-between mb-2">
                <span class="font-sans text-[10px] uppercase tracking-widest text-gray-500">
                  Burst #<%= group_id %> · <%= length(photos) %> photos
                </span>
                <button
                  phx-click="keep_best"
                  phx-value-group={group_id}
                  data-confirm={"Keep the sharpest and reject #{length(rest)} other#{if length(rest) == 1, do: "", else: "s"}?"}
                  class="font-sans text-[10px] uppercase tracking-widest text-purple-700 border border-purple-300 px-2 py-1 hover:border-purple-600 transition-colors"
                >
                  Keep Best
                </button>
              </div>
              <div class="flex gap-2 overflow-x-auto">
                <%= for photo <- photos do %>
                  <div class={[
                    "relative shrink-0 w-32 h-32 border-2",
                    photo.id == best.id && "border-emerald-500",
                    photo.id != best.id && "border-gray-200 opacity-60"
                  ]}>
                    <img src={photo.url} class="w-full h-full object-cover" loading="lazy" />
                    <div class="absolute bottom-0 left-0 right-0 bg-black/60 text-white font-sans text-[9px] px-1 py-0.5 text-center">
                      sharp <%= photo.sharpness_score || "?" %>
                      <%= if photo.id == best.id, do: " ★", else: "" %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- Project filter --%>
      <%= if @projects != [] do %>
        <div class="flex items-center gap-2 mb-8 flex-wrap">
          <span class="font-sans text-[9px] uppercase tracking-widest text-gray-400 shrink-0">Project</span>
          <button
            phx-click="set_project_filter"
            phx-value-project=""
            class={[
              "font-sans text-[10px] uppercase tracking-wider px-3 py-1 border transition-colors",
              is_nil(@project_filter) && "border-[#111111] text-[#111111]",
              !is_nil(@project_filter) && "border-gray-200 text-gray-400 hover:border-gray-500 hover:text-gray-700"
            ]}
          >all</button>
          <%= for proj <- @projects do %>
            <button
              phx-click="set_project_filter"
              phx-value-project={proj}
              class={[
                "font-mono text-[10px] px-3 py-1 border transition-colors",
                @project_filter == proj && "border-[#111111] text-[#111111]",
                @project_filter != proj && "border-gray-200 text-gray-400 hover:border-gray-500 hover:text-gray-700"
              ]}
            ><%= proj %></button>
          <% end %>
        </div>
      <% end %>

      <%!-- Selection toolbar (sticky-feeling, only when there's a selection) --%>
      <%= if MapSet.size(@selected) > 0 do %>
        <div class="sticky top-2 z-10 mb-4 flex flex-col md:flex-row md:items-center gap-3 p-3 border-2 border-[#111111] bg-[#fcfbf9] shadow-sm">
          <p class="font-sans text-xs uppercase tracking-widest text-[#111111] shrink-0">
            <%= MapSet.size(@selected) %> selected
          </p>

          <div class="flex items-center gap-1 flex-wrap">
            <%= for proj <- @projects do %>
              <button
                phx-click="bulk_assign_project"
                phx-value-name={proj}
                class="font-mono text-[10px] px-2 py-1 border border-gray-300 text-gray-700 hover:border-[#111111] hover:text-[#111111] transition-colors"
              ><%= proj %></button>
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
            <button type="submit" class="font-sans text-[10px] uppercase tracking-widest text-gray-700 border border-gray-300 hover:border-[#111111] hover:text-[#111111] px-2 py-1 transition-colors">Assign</button>
          </form>

          <button
            phx-click="bulk_reject"
            data-confirm={"Reject #{MapSet.size(@selected)} photos? (reversible)"}
            class="font-sans text-[10px] uppercase tracking-widest text-red-700 border border-red-300 hover:border-red-600 px-3 py-1 transition-colors shrink-0"
          >Reject</button>
          <button
            phx-click="select_all"
            class="font-sans text-[10px] uppercase tracking-widest text-gray-500 border border-gray-300 hover:border-gray-700 hover:text-gray-700 px-3 py-1 transition-colors shrink-0"
          >Select page</button>
          <button
            phx-click="clear_selection"
            class="font-sans text-[10px] uppercase tracking-widest text-gray-500 hover:text-[#111111] transition-colors shrink-0"
          >Clear</button>
        </div>
      <% end %>

      <%= if @filter != :bursts do %>
      <%!-- Keyboard hint --%>
      <p class="mb-4 font-sans text-[9px] uppercase tracking-widest text-gray-300">
        Click a photo, then: <span class="text-gray-400">1–5</span> rate · <span class="text-gray-400">p</span> pick · <span class="text-gray-400">x</span> reject · <span class="text-gray-400">m</span> select · or use <.link navigate={~p"/review"} class="text-gray-500 underline">Review</.link> for single-image culling
      </p>

      <%!-- Gallery Grid --%>
      <%= if @photos == [] do %>
        <div class="text-center py-24 text-gray-400 font-serif italic text-xl">
          <%= cond do %>
            <% @total == 0 -> %>
              No photos yet. <.link navigate={~p"/"} class="border-b border-gray-400">Ingest from a directory.</.link>
            <% @search != "" -> %>
              No photos match "<%= @search %>".
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
                  !selected? && "bg-[#fcfbf9]/90 text-transparent border-2 border-gray-300 opacity-0 group-hover:opacity-100 hover:border-[#111111] hover:text-gray-500"
                ]}
              >✓</button>
              <%= if photo.url do %>
                <img
                  src={photo.url}
                  alt={photo.subject || "Photo"}
                  class="object-cover w-full h-full transition-transform duration-500 group-hover:scale-105"
                />
              <% else %>
                <div class="w-full h-full flex flex-col items-center justify-center gap-2 bg-gray-100">
                  <span class="text-red-400 font-sans text-lg">✗</span>
                  <span class="font-mono text-[9px] text-gray-400 text-center px-2 leading-snug truncate w-full text-center"><%= Path.basename(photo.file_path || "") %></span>
                </div>
              <% end %>

              <%!-- Primary score — top-left --%>
              <% primary = vibe || photo.preference_score %>
              <%= if primary do %>
                <div class={[
                  "absolute top-2 left-2 font-sans text-[11px] font-bold tabular-nums px-2 py-1",
                  primary >= 70 && "bg-[#111111] text-[#fcfbf9]",
                  primary >= 40 and primary < 70 && "bg-[#fcfbf9]/90 text-gray-600 border border-gray-300",
                  primary < 40 && "bg-[#fcfbf9]/70 text-gray-400 border border-gray-200"
                ]}>
                  <%= primary %>
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
                    <%= photo.project %>
                  </div>
                <% end %>
              </div>

              <%!-- Hover overlay — failed variant --%>
              <%= cond do %>
                <% photo.curation_status == "failed" -> %>
                <div class="absolute inset-0 bg-[#111111]/85 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity duration-300 flex flex-col justify-center items-center gap-3 p-4">
                  <p class="font-sans text-[10px] uppercase tracking-widest text-red-400 text-center">Curation failed</p>
                  <%= if photo.failure_reason && photo.failure_reason != "" do %>
                    <p class="font-mono text-[9px] text-gray-400 text-center leading-snug px-2 truncate w-full"><%= photo.failure_reason %></p>
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
                  <p class="font-sans text-[10px] uppercase tracking-widest text-red-400 text-center">Rejected</p>
                  <p class="font-mono text-[9px] text-gray-500 text-center leading-snug px-2 truncate w-full"><%= Path.basename(photo.file_path || "") %></p>
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

                <p class="text-[#fcfbf9] font-serif text-sm leading-snug mb-1"><%= photo.subject %></p>

                <%!-- Score breakdown --%>
                <div class="flex items-center gap-1.5 mt-1 mb-1 flex-wrap">
                  <%= if vibe do %>
                    <span class="font-sans text-[9px] uppercase tracking-wider text-gray-400 border border-gray-700 px-1.5 py-0.5">vibe <%= vibe %></span>
                  <% end %>
                  <%= if photo.preference_score do %>
                    <span class="font-sans text-[9px] uppercase tracking-wider text-gray-400 border border-gray-700 px-1.5 py-0.5">pref <%= photo.preference_score %></span>
                  <% end %>
                  <%= if photo.technical_score do %>
                    <span class="font-sans text-[9px] uppercase tracking-wider text-gray-400 border border-gray-700 px-1.5 py-0.5">tech <%= photo.technical_score %></span>
                  <% end %>
                  <%= if photo.content_type do %>
                    <span class="font-sans text-[9px] uppercase tracking-wider text-gray-500"><%= photo.content_type %></span>
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
                      <%= String.downcase(tag) %><span class="opacity-0 group-hover/tag:opacity-100 transition-opacity leading-none">×</span>
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
                          !(photo.user_rating && photo.user_rating >= star) && "text-gray-600 hover:text-gray-300"
                        ]}
                      >★</button>
                    <% end %>
                  </div>
                  <button
                    phx-click="toggle_match"
                    phx-value-id={photo.id}
                    title="Chef's pick — manual override, independent of the preference score"
                    class={[
                      "font-sans text-[10px] uppercase tracking-widest px-2 py-1 transition-colors",
                      photo.manual_match && "bg-amber-400 text-[#111111] border border-amber-400 hover:bg-amber-300",
                      !photo.manual_match && "text-gray-500 border border-gray-700 hover:border-amber-400 hover:text-amber-300"
                    ]}
                  >
                    <%= if photo.manual_match, do: "★ picked", else: "☆ pick" %>
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
                  <button type="submit" class="text-gray-500 hover:text-gray-200 font-sans text-xs px-1 uppercase tracking-wider">set</button>
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
              <button phx-click="page" phx-value-n={@page - 1} class="border border-gray-300 px-4 py-2 hover:border-[#111111] transition-colors">← Prev</button>
            <% end %>
            <span class="px-4 py-2 text-gray-400">
              <%= @page %> / <%= @pages %>
            </span>
            <%= if @page < @pages do %>
              <button phx-click="page" phx-value-n={@page + 1} class="border border-gray-300 px-4 py-2 hover:border-[#111111] transition-colors">Next →</button>
            <% end %>
          </div>
        <% end %>
      <% end %>
      <% end %><%!-- /if @filter != :bursts --%>

    </div>
    """
  end
end
