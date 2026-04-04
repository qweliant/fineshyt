defmodule OrchestratorWeb.GalleryLive do
  use OrchestratorWeb, :live_view

  alias Orchestrator.Photos

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, "photo_updates")

    socket =
      socket
      |> assign(:photos, Photos.list_photos())
      |> assign(:tag_profile, Photos.tag_affinity_profile())
      |> assign(:filter, :all)
      |> assign(:sort, :newest)
      |> assign(:search, "")

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    atom = case filter do
      "all" -> :all
      "match" -> :match
      "no_match" -> :no_match
      "rated" -> :rated
      "unrated" -> :unrated
      _ -> :all
    end
    {:noreply, assign(socket, :filter, atom)}
  end

  @impl Phoenix.LiveView
  def handle_event("set_sort", %{"sort" => sort}, socket) do
    atom = case sort do
      "newest" -> :newest
      "score_desc" -> :score_desc
      "score_asc" -> :score_asc
      "rating_desc" -> :rating_desc
      _ -> :newest
    end
    {:noreply, assign(socket, :sort, atom)}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, :search, String.downcase(String.trim(q)))}
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
  def handle_event("delete_tag", %{"id" => id, "tag" => tag}, socket) do
    Photos.delete_tag(String.to_integer(id), tag)
    {:noreply, assign(socket, :photos, Photos.list_photos())}
  end

  @impl Phoenix.LiveView
  def handle_event("add_tag", %{"id" => id, "tag" => tag}, socket) do
    Photos.add_tag(String.to_integer(id), tag)
    {:noreply, assign(socket, :photos, Photos.list_photos())}
  end

  @impl Phoenix.LiveView
  def handle_event("set_project", %{"_id" => id, "project" => project}, socket) do
    Photos.set_project(String.to_integer(id), String.trim(project))
    {:noreply, assign(socket, :photos, Photos.list_photos())}
  end

  @impl Phoenix.LiveView
  def handle_event("delete_photo", %{"id" => id}, socket) do
    Photos.delete_photo(String.to_integer(id))
    {:noreply, assign(socket,
      photos: Photos.list_photos(),
      tag_profile: Photos.tag_affinity_profile()
    )}
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_complete, _ref, _metadata, _basename}, socket) do
    {:noreply, assign(socket,
      photos: Photos.list_photos(),
      tag_profile: Photos.tag_affinity_profile()
    )}
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_failed, _ref, _reason}, socket), do: {:noreply, socket}

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  defp filtered_photos(photos, :all), do: photos
  defp filtered_photos(photos, :match), do: Enum.filter(photos, & &1.style_match)
  defp filtered_photos(photos, :no_match), do: Enum.filter(photos, &(&1.style_match == false))
  defp filtered_photos(photos, :rated), do: Enum.filter(photos, & &1.user_rating)
  defp filtered_photos(photos, :unrated), do: Enum.filter(photos, &is_nil(&1.user_rating))

  defp sorted_photos(photos, :newest), do: photos
  defp sorted_photos(photos, :score_desc), do: Enum.sort_by(photos, & &1.style_score || 0, :desc)
  defp sorted_photos(photos, :score_asc), do: Enum.sort_by(photos, & &1.style_score || 0, :asc)
  defp sorted_photos(photos, :rating_desc), do: Enum.sort_by(photos, & &1.user_rating || 0, :desc)

  defp searched_photos(photos, ""), do: photos
  defp searched_photos(photos, q) do
    Enum.filter(photos, fn p ->
      subject = String.downcase(p.subject || "")
      tags = Enum.map(p.suggested_tags || [], &String.downcase/1)
      mood = String.downcase(p.artistic_mood || "")
      String.contains?(subject, q) or
        String.contains?(mood, q) or
        Enum.any?(tags, &String.contains?(&1, q))
    end)
  end

  defp display_photos(photos, filter, sort, search) do
    photos
    |> filtered_photos(filter)
    |> searched_photos(search)
    |> sorted_photos(sort)
  end

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
        <div class="mt-6 md:mt-0 font-sans uppercase tracking-widest text-xs">
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
            placeholder="search subjects, tags, mood…"
            value={@search}
            phx-change="search"
            phx-debounce="200"
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
          <option value="newest" selected={@sort == :newest}>Newest</option>
          <option value="score_desc" selected={@sort == :score_desc}>Score ↓</option>
          <option value="score_asc" selected={@sort == :score_asc}>Score ↑</option>
          <option value="rating_desc" selected={@sort == :rating_desc}>Rating ↓</option>
        </select>
      </div>

      <%!-- Filter Tabs --%>
      <div class="flex gap-0 mb-10 border-b border-gray-200 overflow-x-auto">
        <%= for {label, value} <- [
          {"All", :all},
          {"Match ✓", :match},
          {"No Match ✗", :no_match},
          {"Rated", :rated},
          {"Unrated", :unrated}
        ] do %>
          <% count = length(display_photos(@photos, value, @sort, @search)) %>
          <button
            phx-click="set_filter"
            phx-value-filter={value}
            class={[
              "font-sans uppercase tracking-widest text-xs px-5 py-3 border-b-2 transition-colors whitespace-nowrap shrink-0",
              @filter == value && "border-[#111111] text-[#111111]",
              @filter != value && "border-transparent text-gray-400 hover:text-gray-600"
            ]}
          >
            <%= label %> (<%= count %>)
          </button>
        <% end %>
      </div>

      <%!-- Gallery Grid --%>
      <% visible = display_photos(@photos, @filter, @sort, @search) %>
      <%= if visible == [] do %>
        <div class="text-center py-24 text-gray-400 font-serif italic text-xl">
          <%= cond do %>
            <% @photos == [] -> %>
              No photos yet. <.link navigate={~p"/"} class="border-b border-gray-400">Ingest from a directory.</.link>
            <% @search != "" -> %>
              No photos match "<%= @search %>".
            <% true -> %>
              No photos match this filter.
          <% end %>
        </div>
      <% else %>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
          <%= for photo <- visible do %>
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
                <%= if photo.project do %>
                  <div class="bg-[#fcfbf9] border border-gray-400 font-sans text-[10px] uppercase tracking-wider px-2 py-1 text-gray-600 max-w-[80px] truncate">
                    <%= photo.project %>
                  </div>
                <% end %>
              </div>

              <%!-- Hover overlay --%>
              <div class="absolute inset-0 bg-[#111111]/80 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity duration-300 flex flex-col justify-end p-4">

                <%!-- Delete button top-left --%>
                <button
                  phx-click="delete_photo"
                  phx-value-id={photo.id}
                  data-confirm="Remove this photo from the archive?"
                  class="absolute top-2 left-2 font-sans text-[9px] uppercase tracking-widest text-gray-600 hover:text-red-400 border border-gray-800 hover:border-red-600 px-2 py-1 transition-colors"
                >
                  delete
                </button>

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

                <%!-- Tags: deletable + add new --%>
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
                  <form phx-submit="add_tag" class="flex">
                    <input type="hidden" name="id" value={photo.id} />
                    <input
                      type="text"
                      name="tag"
                      placeholder="+ tag"
                      maxlength="30"
                      class="font-sans text-[10px] uppercase tracking-wider border border-gray-700 border-dashed text-gray-500 bg-transparent px-1.5 py-0.5 w-16 focus:outline-none focus:border-gray-400 focus:text-gray-300 placeholder-gray-700"
                    />
                  </form>
                </div>

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
                  <input type="hidden" name="_id" value={photo.id} />
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
