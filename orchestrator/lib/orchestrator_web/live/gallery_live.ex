defmodule OrchestratorWeb.GalleryLive do
  use OrchestratorWeb, :live_view

  import Ecto.Query

  alias Orchestrator.Photos
  alias Orchestrator.Workers.LocalBatchImportWorker

  @default_style """
  Photos that lack an obvious sense of place. High grain. Soft focus or motion blur acceptable and often preferable to technical sharpness. B&W or heavily desaturated. Subject ambiguous or secondary to atmosphere. Mood: solitary, searching, still. Framing within frames (windows, doorways, reflections) a recurring pattern. No immediate meaning — meaning deferred.\
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, "photo_updates")

    socket =
      socket
      |> assign(:photos, Photos.list_photos())
      |> assign(:tag_profile, Photos.tag_affinity_profile())
      |> assign(:filter, :all)
      |> assign(:style_description, @default_style)
      |> assign(:importing, false)
      |> assign(:import_queued, 0)
      |> assign(:import_processed, 0)
      |> assign(:import_error, nil)
      |> assign(:activity_log, [])

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, String.to_existing_atom(filter))}
  end

  @impl Phoenix.LiveView
  def handle_event("import", params, socket) do
    dir_path = params |> Map.get("dir_path", "") |> String.trim()
    style = Map.get(params, "style_description", @default_style)
    sample = case Integer.parse(Map.get(params, "sample", "50")) do
      {n, _} when n > 0 -> n
      _ -> 50
    end

    if dir_path != "" do
      %{"dir_path" => dir_path, "style_description" => style, "sample" => sample}
      |> LocalBatchImportWorker.new()
      |> Oban.insert()
    end

    {:noreply, assign(socket,
      importing: dir_path != "",
      import_error: nil,
      import_queued: 0,
      import_processed: 0,
      activity_log: []
    )}
  end

  @impl Phoenix.LiveView
  def handle_event("stop_import", _params, socket) do
    Oban.cancel_all_jobs(from(j in Oban.Job, where: j.queue == "ai_jobs"))
    {:noreply, assign(socket, importing: false)}
  end

  @impl Phoenix.LiveView
  def handle_event("clear_log", _params, socket) do
    {:noreply, assign(socket, activity_log: [])}
  end

  @impl Phoenix.LiveView
  def handle_event("override_score", %{"id" => id, "score" => score}, socket) do
    Photos.override_curation(String.to_integer(id), %{style_score: String.to_integer(score)})
    {:noreply, assign(socket, :photos, Photos.list_photos())}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_match", %{"id" => id}, socket) do
    photo = Photos.get_photo!(String.to_integer(id))
    Photos.override_curation(photo.id, %{style_match: !photo.style_match})
    {:noreply, assign(socket, :photos, Photos.list_photos())}
  end

  @impl Phoenix.LiveView
  def handle_event("rate", %{"id" => id, "rating" => rating_str}, socket) do
    rating = String.to_integer(rating_str)
    Photos.rate_photo(String.to_integer(id), rating)
    profile = Photos.tag_affinity_profile()
    photos = Photos.list_photos()
    {:noreply, assign(socket, photos: photos, tag_profile: profile)}
  end

  @impl Phoenix.LiveView
  def handle_event("set_project", %{"id" => id, "project" => project}, socket) do
    Photos.set_project(String.to_integer(id), String.trim(project))
    {:noreply, assign(socket, :photos, Photos.list_photos())}
  end

  @impl Phoenix.LiveView
  def handle_info({:import_started, count}, socket) do
    {:noreply, assign(socket, importing: true, import_queued: count, import_error: nil)}
  end

  @impl Phoenix.LiveView
  def handle_info({:import_failed, reason}, socket) do
    {:noreply, assign(socket, importing: false, import_error: reason)}
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_complete, _ref, metadata, basename}, socket) do
    entry = %{
      filename: basename,
      subject: metadata["subject"] || "—",
      score: metadata["style_score"] || 0,
      match: metadata["style_match"] || false
    }

    log = [entry | socket.assigns.activity_log] |> Enum.take(50)
    processed = socket.assigns.import_processed + 1
    done = processed >= socket.assigns.import_queued and socket.assigns.import_queued > 0

    {:noreply,
     socket
     |> assign(:photos, Photos.list_photos())
     |> assign(:activity_log, log)
     |> assign(:import_processed, processed)
     |> assign(:importing, not done)}
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_failed, _ref, _reason}, socket) do
    processed = socket.assigns.import_processed + 1
    done = processed >= socket.assigns.import_queued and socket.assigns.import_queued > 0

    {:noreply,
     socket
     |> assign(:photos, Photos.list_photos())
     |> assign(:import_processed, processed)
     |> assign(:importing, not done)}
  end

  defp filtered_photos(photos, :all), do: photos
  defp filtered_photos(photos, :match), do: Enum.filter(photos, & &1.style_match)
  defp filtered_photos(photos, :no_match), do: Enum.filter(photos, &(&1.style_match == false))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#fcfbf9] text-[#111111] font-serif p-6 md:p-12 lg:p-24">

      <%!-- Header --%>
      <header class="mb-12 border-b-[3px] border-[#111111] pb-6 flex flex-col md:flex-row md:items-end justify-between">
        <div>
          <h1 class="text-6xl md:text-8xl font-black tracking-tight leading-none">FINE.<br/>SHYT.</h1>
          <p class="mt-4 text-lg font-light italic text-gray-600">The Archive.</p>
        </div>
        <div class="mt-6 md:mt-0">
          <.link navigate={~p"/"} class="font-sans uppercase tracking-widest text-xs border-b border-[#111111] pb-1 hover:text-gray-500 hover:border-gray-500 transition-colors">
            ← Curate Single Photo
          </.link>
        </div>
      </header>

      <%!-- Local Ingest Controls --%>
      <form phx-submit="import" class="mb-10 flex flex-col gap-4">
        <div class="flex flex-col md:flex-row gap-4">
          <div class="flex-1">
            <label class="font-sans uppercase tracking-widest text-xs block mb-2 text-gray-500">Directory</label>
            <input
              type="text"
              name="dir_path"
              placeholder="/Volumes/drive/photos/2024"
              class="w-full border border-[#111111] bg-transparent px-4 py-3 font-sans text-sm focus:outline-none focus:ring-1 focus:ring-[#111111]"
            />
          </div>
          <div class="md:w-32">
            <label class="font-sans uppercase tracking-widest text-xs block mb-2 text-gray-500">Sample N</label>
            <input
              type="number"
              name="sample"
              value="50"
              min="1"
              class="w-full border border-[#111111] bg-transparent px-4 py-3 font-sans text-sm focus:outline-none focus:ring-1 focus:ring-[#111111]"
            />
          </div>
        </div>
        <div>
          <label class="font-sans uppercase tracking-widest text-xs block mb-2 text-gray-500">Style Description</label>
          <textarea
            name="style_description"
            rows="3"
            class="w-full border border-[#111111] bg-transparent px-4 py-3 font-sans text-sm focus:outline-none focus:ring-1 focus:ring-[#111111] resize-none"
          ><%= @style_description %></textarea>
        </div>
        <div class="flex justify-end">
          <button
            type="submit"
            disabled={@importing}
            class="font-sans uppercase tracking-widest text-sm bg-[#111111] text-[#fcfbf9] px-8 py-3 hover:bg-gray-800 transition-colors disabled:opacity-40 disabled:cursor-not-allowed whitespace-nowrap"
          >
            <%= if @importing do %>
              <span class="flex items-center gap-2">
                <span class="w-2 h-2 bg-[#fcfbf9] rounded-full animate-ping"></span>
                Ingesting...
              </span>
            <% else %>
              Ingest from Directory →
            <% end %>
          </button>
        </div>
      </form>

      <%!-- Import error --%>
      <%= if @import_error do %>
        <div class="mb-6 border border-red-800 px-5 py-3 flex items-start gap-3">
          <span class="font-sans uppercase tracking-widest text-xs font-bold text-red-800 whitespace-nowrap mt-0.5">Ingest Failed</span>
          <span class="font-sans text-xs text-red-700 leading-relaxed"><%= @import_error %></span>
        </div>
      <% end %>

      <%!-- Activity Log --%>
      <%= if @importing or @activity_log != [] do %>
        <div class="mb-10 border border-gray-200">
          <div class="flex items-center justify-between px-4 py-2 border-b border-gray-200 bg-gray-50">
            <span class="font-sans text-xs uppercase tracking-widest text-gray-500 flex items-center gap-2">
              <%= if @importing do %>
                <span class="w-1.5 h-1.5 bg-[#111111] rounded-full animate-ping inline-block"></span>
                Processing <%= @import_processed %> / <%= @import_queued %>
              <% else %>
                Done — <%= @import_processed %> processed
              <% end %>
            </span>
            <div class="flex items-center gap-3">
              <%= if @importing do %>
                <button
                  phx-click="stop_import"
                  class="font-sans text-xs uppercase tracking-widest text-red-700 border border-red-300 px-3 py-1 hover:border-red-700 hover:text-red-900 transition-colors"
                >
                  Stop ×
                </button>
              <% end %>
              <button
                phx-click="clear_log"
                class="font-sans text-xs uppercase tracking-widest text-gray-400 hover:text-gray-700 transition-colors"
              >
                Clear
              </button>
            </div>
          </div>
          <div class="divide-y divide-gray-100 max-h-52 overflow-y-auto">
            <%= for entry <- @activity_log do %>
              <div class="flex items-center gap-3 px-4 py-2 font-mono text-xs">
                <span class={["w-3 shrink-0", entry.match && "text-[#111111]", !entry.match && "text-gray-300"]}>
                  <%= if entry.match, do: "✓", else: "—" %>
                </span>
                <span class="w-44 shrink-0 text-gray-500 truncate"><%= entry.filename %></span>
                <span class="flex-1 text-gray-400 truncate italic"><%= entry.subject %></span>
                <span class={[
                  "shrink-0 font-bold tabular-nums",
                  entry.score >= 75 && "text-[#111111]",
                  entry.score < 75 && "text-gray-400"
                ]}>
                  <%= entry.score %>
                </span>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Filter Tabs --%>
      <div class="flex gap-0 mb-10 border-b border-gray-200">
        <%= for {label, value, count} <- [
          {"All", :all, length(@photos)},
          {"Style Match ✓", :match, length(filtered_photos(@photos, :match))},
          {"No Match ✗", :no_match, length(filtered_photos(@photos, :no_match))}
        ] do %>
          <button
            phx-click="set_filter"
            phx-value-filter={value}
            class={[
              "font-sans uppercase tracking-widest text-xs px-6 py-3 border-b-2 transition-colors",
              @filter == value && "border-[#111111] text-[#111111]",
              @filter != value && "border-transparent text-gray-400 hover:text-gray-600"
            ]}
          >
            <%= label %> (<%= count %>)
          </button>
        <% end %>
      </div>

      <%!-- Gallery Grid --%>
      <%= if filtered_photos(@photos, @filter) == [] do %>
        <div class="text-center py-24 text-gray-400 font-serif italic text-xl">
          <%= if @photos == [] do %>
            No photos yet. Point at a directory and ingest, or curate a single photo.
          <% else %>
            No photos match this filter.
          <% end %>
        </div>
      <% else %>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
          <%= for photo <- filtered_photos(@photos, @filter) do %>
            <% vibe = Photos.vibe_score(photo, @tag_profile) %>
            <div class="group relative aspect-square overflow-hidden border border-gray-200 bg-gray-50">
              <img
                src={photo.url}
                alt={photo.subject || "Photo"}
                class="object-cover w-full h-full transition-transform duration-500 group-hover:scale-105"
              />

              <%!-- Top badges --%>
              <div class="absolute top-2 right-2 flex flex-col items-end gap-1">
                <div class={[
                  "font-sans text-xs font-bold uppercase tracking-wider px-2 py-1",
                  photo.style_match && "bg-[#111111] text-[#fcfbf9]",
                  photo.style_match == false && "bg-white text-gray-500 border border-gray-300"
                ]}>
                  <%= if photo.style_match, do: "✓ Match", else: "✗ No" %>
                </div>
                <%= if vibe do %>
                  <div class="bg-[#fcfbf9] border border-[#111111] font-sans text-[10px] uppercase tracking-wider px-2 py-1 font-bold">
                    vibe <%= vibe %>
                  </div>
                <% end %>
                <%= if photo.project do %>
                  <div class="bg-[#fcfbf9] border border-gray-400 font-sans text-[10px] uppercase tracking-wider px-2 py-1 text-gray-600 max-w-[80px] truncate">
                    <%= photo.project %>
                  </div>
                <% end %>
              </div>

              <%!-- Hover overlay --%>
              <div class="absolute inset-0 bg-[#111111]/80 opacity-0 group-hover:opacity-100 transition-opacity duration-300 flex flex-col justify-end p-4">
                <p class="text-[#fcfbf9] font-serif text-sm leading-snug mb-1"><%= photo.subject %></p>

                <%!-- Score slider --%>
                <div class="flex items-center gap-2 mt-1">
                  <input
                    type="range"
                    min="0"
                    max="100"
                    value={photo.style_score || 0}
                    phx-change="override_score"
                    phx-debounce="300"
                    phx-value-id={photo.id}
                    name="score"
                    class="flex-1 h-px cursor-pointer [accent-color:white]"
                  />
                  <span class="text-gray-300 font-sans text-xs tabular-nums w-6 text-right shrink-0">
                    <%= photo.style_score || 0 %>
                  </span>
                </div>

                <%= if photo.style_reason && photo.style_reason != "" do %>
                  <p class="text-gray-400 font-sans text-xs mt-1 italic leading-snug"><%= photo.style_reason %></p>
                <% end %>
                <%= if photo.suggested_tags != [] do %>
                  <div class="flex flex-wrap gap-1 mt-2">
                    <%= for tag <- photo.suggested_tags do %>
                      <span class="font-sans text-[10px] uppercase tracking-wider border border-gray-500 text-gray-300 px-1.5 py-0.5">
                        <%= String.downcase(tag) %>
                      </span>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Star rating + match toggle --%>
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

                <%!-- Project assignment --%>
                <form phx-submit="set_project" class="mt-2 flex gap-1">
                  <input type="hidden" name="id" value={photo.id} />
                  <input
                    type="text"
                    name="project"
                    value={photo.project || ""}
                    placeholder="project..."
                    class="flex-1 bg-transparent border-b border-gray-600 text-gray-300 font-sans text-xs px-1 py-0.5 focus:outline-none focus:border-gray-300 placeholder-gray-600"
                  />
                  <button type="submit" class="text-gray-500 hover:text-gray-200 font-sans text-xs px-1 uppercase tracking-wider">
                    set
                  </button>
                </form>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

    </div>
    """
  end
end
