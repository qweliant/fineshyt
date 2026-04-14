defmodule OrchestratorWeb.ProjectsLive do
  use OrchestratorWeb, :live_view

  alias Orchestrator.Photos

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, "photo_updates")

    {:ok, socket
      |> assign(:selected_project, nil)
      |> assign(:project_photos, [])
      |> assign(:projects, Photos.list_projects_with_covers())}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"p" => project}, _uri, socket) do
    photos = Photos.list_photos(filter: :all, project: project, sort: :score_desc, page: 1)
    {:noreply, socket |> assign(:selected_project, project) |> assign(:project_photos, photos)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:selected_project, nil) |> assign(:project_photos, [])}
  end

  # ── events ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("remove_from_project", %{"id" => id}, socket) do
    Photos.set_project(String.to_integer(id), "")
    project = socket.assigns.selected_project
    photos = Photos.list_photos(filter: :all, project: project, sort: :score_desc, page: 1)
    {:noreply, socket
      |> assign(:project_photos, photos)
      |> assign(:projects, Photos.list_projects_with_covers())}
  end

  # ── pubsub ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_info({:curation_complete, _ref, _metadata, _basename}, socket) do
    {:noreply, assign(socket, :projects, Photos.list_projects_with_covers())}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  # ── render ────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#fcfbf9] text-[#111111] font-serif">

      <%!-- Header --%>
      <div class="border-b border-gray-200 px-8 py-4 flex items-center justify-between">
        <div>
          <span class="font-sans text-xs uppercase tracking-[0.4em] text-gray-400">fineshyt</span>
          <span class="font-sans text-xs text-gray-200 ml-3">·</span>
          <span class="font-sans text-xs uppercase tracking-widest text-gray-300 ml-3">projects</span>
        </div>
        <div class="flex items-center gap-6">
          <.link navigate={~p"/gallery"} class="font-sans text-xs uppercase tracking-widest text-gray-400 hover:text-gray-800 transition-colors border-b border-gray-300 hover:border-gray-800 pb-0.5">
            Gallery
          </.link>
          <.link navigate={~p"/"} class="font-sans text-xs uppercase tracking-widest text-gray-400 hover:text-gray-800 transition-colors border-b border-gray-300 hover:border-gray-800 pb-0.5">
            ← Ingest
          </.link>
        </div>
      </div>

      <div class="p-6 md:p-12 lg:p-24">

        <%!-- Title --%>
        <div class="mb-16 border-b-[3px] border-[#111111] pb-6 flex flex-col md:flex-row md:items-end justify-between">
          <div>
            <%= if @selected_project do %>
              <div class="mb-2">
                <button
                  phx-click="back"
                  onclick="window.history.back()"
                  class="font-sans text-xs uppercase tracking-widest text-gray-400 hover:text-gray-700 transition-colors"
                >
                  ← All Projects
                </button>
              </div>
              <h1 class="text-5xl md:text-7xl font-black tracking-tight leading-none break-words">
                <%= String.upcase(@selected_project) %>
              </h1>
              <p class="mt-4 text-lg font-light italic text-gray-600">
                <%= length(@project_photos) %> photo<%= if length(@project_photos) != 1, do: "s" %>
                <span class="font-sans text-sm not-italic text-gray-400 ml-2">·
                  <.link navigate={~p"/gallery?project=#{@selected_project}"} class="underline hover:text-gray-600">
                    edit in gallery
                  </.link>
                </span>
              </p>
            <% else %>
              <h1 class="text-6xl md:text-8xl font-black tracking-tight leading-none">PROJECTS.</h1>
              <p class="mt-4 text-lg font-light italic text-gray-600">
                <%= length(@projects) %> project<%= if length(@projects) != 1, do: "s" %>
              </p>
            <% end %>
          </div>
          <%= unless @selected_project do %>
            <div class="mt-4 md:mt-0 font-sans text-xs text-gray-400 uppercase tracking-widest max-w-xs text-right">
              Assign photos to projects from the gallery hover overlay.
            </div>
          <% end %>
        </div>

        <%!-- Project overview grid --%>
        <%= if is_nil(@selected_project) do %>
          <%= if @projects == [] do %>
            <div class="text-center py-24 text-gray-400 font-serif italic text-xl">
              No projects yet.
              <p class="mt-4 font-sans text-sm not-italic">
                In the <.link navigate={~p"/gallery"} class="border-b border-gray-400">gallery</.link>,
                hover over a photo and type a project name in the field at the bottom of the overlay.
              </p>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-8">
              <%= for proj <- @projects do %>
                <.link navigate={~p"/projects?p=#{proj.name}"} class="group block">
                  <div class="aspect-[4/3] overflow-hidden border border-gray-200 bg-gray-100 mb-3 relative">
                    <%= if proj.cover_url do %>
                      <img
                        src={proj.cover_url}
                        alt={proj.name}
                        class="object-cover w-full h-full transition-transform duration-700 group-hover:scale-105"
                      />
                    <% else %>
                      <div class="w-full h-full flex items-center justify-center">
                        <span class="font-sans text-xs uppercase tracking-widest text-gray-300">no photos yet</span>
                      </div>
                    <% end %>
                    <div class="absolute inset-0 bg-[#111111]/0 group-hover:bg-[#111111]/20 transition-colors duration-300"></div>
                  </div>
                  <div class="flex items-baseline justify-between">
                    <h2 class="font-serif text-xl font-bold tracking-tight group-hover:text-gray-600 transition-colors"><%= proj.name %></h2>
                    <span class="font-sans text-xs text-gray-400 uppercase tracking-widest"><%= proj.count %></span>
                  </div>
                </.link>
              <% end %>
            </div>
          <% end %>

        <%!-- Project detail --%>
        <% else %>
          <%= if @project_photos == [] do %>
            <div class="text-center py-24 text-gray-400 font-serif italic text-xl">
              No photos in this project.
              <p class="mt-4 font-sans text-sm not-italic">
                <.link navigate={~p"/gallery"} class="border-b border-gray-400">Go to gallery</.link> to assign photos here.
              </p>
            </div>
          <% else %>
            <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
              <%= for photo <- @project_photos do %>
                <div class="group relative aspect-square overflow-hidden border border-gray-200 bg-gray-50">
                  <img
                    src={photo.url}
                    alt={photo.subject || "Photo"}
                    class="object-cover w-full h-full transition-transform duration-500 group-hover:scale-105"
                  />

                  <%!-- Badges --%>
                  <div class="absolute top-2 right-2 flex flex-col items-end gap-1">
                    <%= if photo.preference_score != nil do %>
                      <div class={[
                        "font-sans text-[9px] uppercase tracking-wider px-2 py-0.5 border font-bold",
                        photo.preference_score >= 75 && "bg-fuchsia-900/80 text-fuchsia-200 border-fuchsia-700",
                        photo.preference_score >= 50 && photo.preference_score < 75 && "bg-purple-900/80 text-purple-200 border-purple-700",
                        photo.preference_score < 50 && "bg-gray-800/80 text-gray-300 border-gray-600"
                      ]}>
                        <%= photo.preference_score %>
                      </div>
                    <% end %>
                    <%= if photo.user_rating do %>
                      <div class="bg-[#fcfbf9]/90 border border-gray-300 font-sans text-[9px] px-2 py-0.5 text-gray-600">
                        <%= String.duplicate("★", photo.user_rating) %>
                      </div>
                    <% end %>
                  </div>

                  <%!-- Hover overlay --%>
                  <div class="absolute inset-0 bg-[#111111]/75 opacity-0 group-hover:opacity-100 transition-opacity duration-300 flex flex-col justify-end p-4">
                    <p class="text-[#fcfbf9] font-serif text-sm leading-snug mb-3"><%= photo.subject %></p>
                    <div class="flex items-center justify-between">
                      <.link
                        navigate={~p"/gallery"}
                        class="font-sans text-[10px] uppercase tracking-widest text-gray-400 hover:text-gray-200 transition-colors"
                      >
                        edit →
                      </.link>
                      <button
                        phx-click="remove_from_project"
                        phx-value-id={photo.id}
                        data-confirm="Remove from project?"
                        class="font-sans text-[9px] uppercase tracking-widest text-gray-500 hover:text-red-400 border border-gray-700 hover:border-red-600 px-2 py-1 transition-colors"
                      >
                        remove
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>

      </div>
    </div>
    """
  end
end
