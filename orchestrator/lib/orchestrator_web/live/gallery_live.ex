defmodule OrchestratorWeb.GalleryLive do
  use OrchestratorWeb, :live_view

  alias Orchestrator.Photos

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, "photo_updates")

    socket =
      socket
      |> assign(:filter, :all)
      |> assign(:sort, :newest)
      |> assign(:search, "")
      |> assign(:page, 1)
      |> assign(:project_filter, nil)
      |> assign(:projects, Photos.list_projects())
      |> assign(:tag_profile, Photos.tag_affinity_profile())
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
    opts  = query_opts(socket)
    total = Photos.count_photos(opts)
    pages = max(1, ceil(total / Photos.page_size()))
    assign(socket,
      photos: Photos.list_photos(opts),
      total:  total,
      pages:  pages
    )
  end

  defp reload(socket, overrides) do
    socket
    |> assign(overrides)
    |> assign(:page, 1)
    |> load_photos()
  end

  # ── events ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    atom = case filter do
      "match"    -> :match
      "no_match" -> :no_match
      "rated"    -> :rated
      "unrated"  -> :unrated
      "failed"   -> :failed
      _          -> :all
    end
    {:noreply, reload(socket, filter: atom)}
  end

  @impl Phoenix.LiveView
  def handle_event("set_sort", %{"sort" => sort}, socket) do
    atom = case sort do
      "score_desc"  -> :score_desc
      "score_asc"   -> :score_asc
      "rating_desc" -> :rating_desc
      _             -> :newest
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
        {:noreply, socket |> assign(:tag_profile, Photos.tag_affinity_profile()) |> load_photos()}
      "p" ->
        Photos.rate_photo(photo_id, 5)
        {:noreply, socket |> assign(:tag_profile, Photos.tag_affinity_profile()) |> load_photos()}
      "x" ->
        Photos.delete_photo(photo_id)
        {:noreply, socket |> assign(:tag_profile, Photos.tag_affinity_profile()) |> load_photos()}
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
  def handle_event("override_score", %{"id" => id, "score" => score}, socket) do
    Photos.override_curation(String.to_integer(id), %{style_score: String.to_integer(score)})
    {:noreply, load_photos(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_match", %{"id" => id}, socket) do
    photo = Photos.get_photo!(String.to_integer(id))
    Photos.override_curation(photo.id, %{style_match: !photo.style_match})
    {:noreply, load_photos(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("rate", %{"id" => id, "rating" => rating_str}, socket) do
    Photos.rate_photo(String.to_integer(id), String.to_integer(rating_str))
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
          "project" => project,
          "style_description" => ""
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
        "project" => photo.project,
        "style_description" => ""
      })
      |> Oban.insert()
    end)
    {:noreply, socket |> put_flash(:info, "Re-queued #{length(failed)} failed photos.") |> load_photos()}
  end

  # ── pubsub ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_info({:curation_complete, _ref, _metadata, _basename}, socket) do
    {:noreply, socket
      |> assign(:tag_profile, Photos.tag_affinity_profile())
      |> assign(:projects, Photos.list_projects())
      |> load_photos()}
  end

  def handle_info({:curation_failed, _ref, _basename, _reason}, socket) do
    # Reload so failed tab count stays fresh
    {:noreply, load_photos(socket)}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  # ── render ────────────────────────────────────────────────────────────────

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
          <.link navigate={~p"/projects"} class="border-b border-gray-400 pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors">
            Projects
          </.link>
          <.link navigate={~p"/"} class="border-b border-[#111111] pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors">
            ← Ingest
          </.link>
        </div>
      </header>

      <%!-- Search + Sort bar --%>
      <div class="flex flex-col sm:flex-row gap-4 mb-8">
        <div class="flex-1 relative">
          <input
            type="text"
            placeholder="search subjects, mood…"
            value={@search}
            phx-change="search"
            phx-debounce="300"
            name="q"
            class="w-full border border-gray-300 bg-transparent px-4 py-2.5 font-sans text-sm focus:outline-none focus:border-[#111111] placeholder-gray-300"
          />
          <%= if @search != "" do %>
            <button phx-click="search" phx-value-q="" class="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 hover:text-gray-700 font-sans text-sm">×</button>
          <% end %>
        </div>
        <select
          phx-change="set_sort"
          name="sort"
          class="border border-gray-300 bg-[#fcfbf9] px-4 py-2.5 font-sans text-xs uppercase tracking-widest focus:outline-none focus:border-[#111111] cursor-pointer"
        >
          <option value="newest"      selected={@sort == :newest}>Newest</option>
          <option value="score_desc"  selected={@sort == :score_desc}>Score ↓</option>
          <option value="score_asc"   selected={@sort == :score_asc}>Score ↑</option>
          <option value="rating_desc" selected={@sort == :rating_desc}>Rating ↓</option>
        </select>
      </div>

      <%!-- Filter Tabs --%>
      <div class="flex gap-0 mb-4 border-b border-gray-200 overflow-x-auto">
        <%= for {label, value} <- [
          {"All", :all}, {"Match ✓", :match}, {"No Match ✗", :no_match},
          {"Rated", :rated}, {"Unrated", :unrated}, {"Failed", :failed}
        ] do %>
          <button
            phx-click="set_filter"
            phx-value-filter={value}
            class={[
              "font-sans uppercase tracking-widest text-xs px-5 py-3 border-b-2 transition-colors whitespace-nowrap shrink-0",
              @filter == value && value == :failed && "border-red-600 text-red-600",
              @filter == value && value != :failed && "border-[#111111] text-[#111111]",
              @filter != value && value == :failed && "border-transparent text-red-300 hover:text-red-500",
              @filter != value && value != :failed && "border-transparent text-gray-400 hover:text-gray-600"
            ]}
          >
            <%= label %>
          </button>
        <% end %>
      </div>

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

      <%!-- Keyboard hint --%>
      <p class="mb-4 font-sans text-[9px] uppercase tracking-widest text-gray-300">
        Click a photo, then: <span class="text-gray-400">1–5</span> rate · <span class="text-gray-400">p</span> pick · <span class="text-gray-400">x</span> reject
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
            <div
              class="group relative aspect-square overflow-hidden border border-gray-200 bg-gray-50 focus:outline-none focus:ring-2 focus:ring-[#111111] focus:ring-offset-1"
              tabindex="0"
              phx-keydown="photo_keydown"
              phx-value-id={photo.id}
            >
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

              <%!-- Top badges --%>
              <div class="absolute top-2 right-2 flex flex-col items-end gap-1">
                <div class={[
                  "font-sans text-xs font-bold uppercase tracking-wider px-2 py-1",
                  photo.style_match && "bg-[#111111] text-[#fcfbf9]",
                  photo.style_match == false && "bg-white text-gray-500 border border-gray-300"
                ]}>
                  <%= if photo.style_match, do: "✓ Match", else: "✗ No" %>
                </div>
                <%= if photo.style_score != nil do %>
                  <% conf = photo.style_score
                     {conf_label, conf_class} = cond do
                       conf >= 80 -> {"high conf", "bg-emerald-900/80 text-emerald-300 border-emerald-700"}
                       conf >= 50 -> {"med conf", "bg-yellow-900/80 text-yellow-300 border-yellow-700"}
                       true       -> {"low conf", "bg-red-900/80 text-red-300 border-red-700"}
                     end %>
                  <div class={["font-sans text-[9px] uppercase tracking-wider px-2 py-0.5 border font-bold", conf_class]}>
                    <%= conf_label %> · <%= conf %>
                  </div>
                <% end %>
                <%= if vibe do %>
                  <div class="bg-[#fcfbf9] border border-[#111111] font-sans text-[10px] uppercase tracking-wider px-2 py-1 font-bold">
                    vibe <%= vibe %>
                  </div>
                <% end %>
                <%= if photo.content_type do %>
                  <div class="bg-[#fcfbf9]/90 border border-gray-300 font-sans text-[9px] uppercase tracking-wider px-2 py-0.5 text-gray-500">
                    <%= photo.content_type %>
                  </div>
                <% end %>
                <%= if photo.project do %>
                  <div class="bg-[#fcfbf9] border border-gray-400 font-sans text-[10px] uppercase tracking-wider px-2 py-1 text-gray-600 max-w-[80px] truncate">
                    <%= photo.project %>
                  </div>
                <% end %>
              </div>

              <%!-- Hover overlay — failed variant --%>
              <%= if photo.curation_status == "failed" do %>
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
              <% else %>
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

                <div class="flex items-center gap-2 mt-1">
                  <input
                    type="range" min="0" max="100"
                    value={photo.style_score || 0}
                    phx-change="override_score"
                    phx-debounce="300"
                    phx-value-id={photo.id}
                    name="score"
                    oninput="this.nextElementSibling.textContent = this.value"
                    class="flex-1 h-px cursor-pointer [accent-color:white]"
                  />
                  <span class="text-gray-300 font-sans text-xs tabular-nums w-6 text-right shrink-0">
                    <%= photo.style_score || 0 %>
                  </span>
                </div>

                <%= if photo.style_reason && photo.style_reason != "" do %>
                  <div class="mt-2 border-l-2 border-gray-700 pl-2">
                    <p class="font-sans text-[9px] uppercase tracking-widest text-gray-600 mb-0.5">model says</p>
                    <p class="text-gray-400 font-sans text-[10px] italic leading-snug"><%= photo.style_reason %></p>
                  </div>
                <% end %>

                <div class="flex flex-wrap gap-1 mt-2">
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
                    class={[
                      "font-sans text-[10px] uppercase tracking-widest px-2 py-1 transition-colors",
                      photo.style_match && "text-[#fcfbf9] border border-gray-500 hover:border-red-400 hover:text-red-400",
                      !photo.style_match && "text-gray-500 border border-gray-700 hover:border-gray-400 hover:text-gray-300"
                    ]}
                  >
                    <%= if photo.style_match, do: "✓ match", else: "✗ no" %>
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

    </div>
    """
  end
end
