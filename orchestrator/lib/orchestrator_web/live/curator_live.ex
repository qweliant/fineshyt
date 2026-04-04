defmodule OrchestratorWeb.CuratorLive do
  use OrchestratorWeb, :live_view

  import Ecto.Query

  alias Orchestrator.Workers.LocalBatchImportWorker

  @default_style """
  Photos that lack an obvious sense of place. High grain. Soft focus or motion blur acceptable and often preferable to technical sharpness. B&W or heavily desaturated. Subject ambiguous or secondary to atmosphere. Mood: solitary, searching, still. Framing within frames (windows, doorways, reflections) a recurring pattern. No immediate meaning — meaning deferred.\
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, "photo_updates")

    socket =
      socket
      |> assign(:status, :idle)
      |> assign(:dir_path, "")
      |> assign(:style_description, @default_style)
      |> assign(:sample, 50)
      |> assign(:import_queued, 0)
      |> assign(:import_processed, 0)
      |> assign(:import_error, nil)
      |> assign(:activity_log, [])

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("set_path", %{"dir_path" => path}, socket) do
    {:noreply, assign(socket, dir_path: path)}
  end

  @impl Phoenix.LiveView
  def handle_event("ingest", params, socket) do
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
      status: if(dir_path != "", do: :ingesting, else: :idle),
      dir_path: dir_path,
      import_error: nil,
      import_queued: 0,
      import_processed: 0,
      activity_log: []
    )}
  end

  @impl Phoenix.LiveView
  def handle_event("stop", _params, socket) do
    Oban.cancel_all_jobs(from(j in Oban.Job, where: j.queue == "ai_jobs"))
    {:noreply, assign(socket, status: :idle)}
  end

  @impl Phoenix.LiveView
  def handle_event("clear_log", _params, socket) do
    {:noreply, assign(socket, activity_log: [])}
  end

  @impl Phoenix.LiveView
  def handle_info({:import_started, count}, socket) do
    {:noreply, assign(socket, status: :ingesting, import_queued: count)}
  end

  @impl Phoenix.LiveView
  def handle_info({:import_failed, reason}, socket) do
    {:noreply, assign(socket, status: :idle, import_error: reason)}
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_complete, _ref, metadata, basename}, socket) do
    entry = %{
      filename: basename,
      subject: metadata["subject"] || "—",
      score: metadata["style_score"] || 0,
      match: metadata["style_match"] || false
    }
    log = [entry | socket.assigns.activity_log] |> Enum.take(100)
    processed = socket.assigns.import_processed + 1
    done = processed >= socket.assigns.import_queued and socket.assigns.import_queued > 0

    {:noreply, socket
      |> assign(:activity_log, log)
      |> assign(:import_processed, processed)
      |> assign(:status, if(done, do: :done, else: :ingesting))}
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_failed, _ref, _reason}, socket) do
    processed = socket.assigns.import_processed + 1
    done = processed >= socket.assigns.import_queued and socket.assigns.import_queued > 0
    {:noreply, socket
      |> assign(:import_processed, processed)
      |> assign(:status, if(done, do: :done, else: :ingesting))}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#0a0a0f] text-[#e8e6e0] font-serif selection:bg-white selection:text-black">

      <%!-- Header bar --%>
      <div class="border-b border-white/5 px-8 py-4 flex items-center justify-between">
        <div>
          <span class="font-sans text-xs uppercase tracking-[0.4em] text-white/30">fineshyt</span>
          <span class="font-sans text-xs text-white/10 ml-3">·</span>
          <span class="font-sans text-xs uppercase tracking-widest text-white/20 ml-3">archival system</span>
        </div>
        <div class="flex items-center gap-6">
          <.link navigate={~p"/gallery"} class="font-sans text-xs uppercase tracking-widest text-white/30 hover:text-white/70 transition-colors">
            Gallery →
          </.link>
        </div>
      </div>

      <div class="max-w-4xl mx-auto px-8 py-16">

        <%!-- Title --%>
        <div class="mb-16">
          <h1 class="text-[clamp(3rem,8vw,6rem)] font-black tracking-tight leading-none text-white">
            FINE.<br/>SHYT.
          </h1>
          <p class="mt-4 font-serif italic text-white/30 text-lg">
            Point it at a folder. Let the machine decide.
          </p>
        </div>

        <%!-- Main ingest form --%>
        <form phx-submit="ingest" class="mb-10">

          <%!-- Path input — Pixea-style large path bar --%>
          <div class="mb-2">
            <label class="font-sans text-[10px] uppercase tracking-[0.35em] text-white/25 block mb-3">
              Directory
            </label>
            <div class="flex gap-0 border border-white/10 bg-white/3 focus-within:border-white/25 transition-colors">
              <span class="font-sans text-white/20 text-sm px-4 flex items-center select-none border-r border-white/10">
                /
              </span>
              <input
                type="text"
                name="dir_path"
                value={@dir_path}
                placeholder="Volumes/drive/film/2024"
                phx-change="set_path"
                phx-debounce="200"
                autocomplete="off"
                spellcheck="false"
                class="flex-1 bg-transparent px-4 py-4 font-mono text-sm text-white/80 placeholder-white/15 focus:outline-none"
              />
              <%= if @dir_path != "" do %>
                <button
                  type="button"
                  phx-click="set_path"
                  phx-value-dir_path=""
                  class="px-4 text-white/20 hover:text-white/50 transition-colors font-sans text-sm"
                >
                  ×
                </button>
              <% end %>
            </div>
          </div>

          <%!-- Quick-access suggestions --%>
          <div class="flex gap-2 mb-8 flex-wrap">
            <%= for path <- ["/Volumes", "~/Desktop", "~/Downloads", "~/Pictures"] do %>
              <button
                type="button"
                phx-click="set_path"
                phx-value-dir_path={path}
                class="font-mono text-[10px] text-white/20 border border-white/8 px-2.5 py-1 hover:border-white/30 hover:text-white/50 transition-colors"
              >
                <%= path %>
              </button>
            <% end %>
          </div>

          <%!-- Secondary controls --%>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
            <div class="md:col-span-2">
              <label class="font-sans text-[10px] uppercase tracking-[0.35em] text-white/25 block mb-3">
                Style Description
              </label>
              <textarea
                name="style_description"
                rows="4"
                class="w-full bg-white/3 border border-white/10 focus:border-white/25 px-4 py-3 font-sans text-xs text-white/60 placeholder-white/15 focus:outline-none resize-none transition-colors leading-relaxed"
              ><%= @style_description %></textarea>
            </div>
            <div>
              <label class="font-sans text-[10px] uppercase tracking-[0.35em] text-white/25 block mb-3">
                Sample Size
              </label>
              <input
                type="number"
                name="sample"
                value={@sample}
                min="1"
                max="500"
                class="w-full bg-white/3 border border-white/10 focus:border-white/25 px-4 py-4 font-sans text-sm text-white/60 focus:outline-none transition-colors"
              />
              <p class="mt-2 font-sans text-[9px] text-white/20 leading-relaxed">
                Random sample from the directory. Larger sets take longer.
              </p>
            </div>
          </div>

          <%!-- Submit --%>
          <div class="flex items-center justify-between">
            <div>
              <%= if @import_error do %>
                <p class="font-sans text-xs text-red-400"><%= @import_error %></p>
              <% end %>
            </div>
            <%= if @status == :ingesting do %>
              <div class="flex items-center gap-4">
                <div class="flex items-center gap-2 font-sans text-xs text-white/40">
                  <span class="w-1.5 h-1.5 bg-white/60 rounded-full animate-ping inline-block"></span>
                  <%= @import_processed %> / <%= @import_queued %> processed
                </div>
                <button
                  type="button"
                  phx-click="stop"
                  class="font-sans text-xs uppercase tracking-widest text-red-400 border border-red-800 px-4 py-2 hover:border-red-500 transition-colors"
                >
                  Stop
                </button>
              </div>
            <% else %>
              <button
                type="submit"
                disabled={@dir_path == "" or @status == :ingesting}
                class="font-sans text-xs uppercase tracking-[0.3em] bg-white text-black px-10 py-3.5 hover:bg-white/90 transition-colors disabled:opacity-20 disabled:cursor-not-allowed"
              >
                <%= if @status == :done, do: "Ingest Again →", else: "Ingest →" %>
              </button>
            <% end %>
          </div>
        </form>

        <%!-- Activity log --%>
        <%= if @activity_log != [] do %>
          <div class="border border-white/8">
            <div class="flex items-center justify-between px-4 py-2.5 border-b border-white/8">
              <span class="font-sans text-[10px] uppercase tracking-widest text-white/25">
                <%= if @status == :done, do: "Done — #{@import_processed} curated", else: "Processing..." %>
              </span>
              <button phx-click="clear_log" class="font-sans text-[10px] text-white/20 hover:text-white/50 uppercase tracking-widest transition-colors">
                Clear
              </button>
            </div>
            <div class="divide-y divide-white/4 max-h-80 overflow-y-auto">
              <%= for entry <- @activity_log do %>
                <div class="flex items-center gap-3 px-4 py-2 font-mono text-xs">
                  <span class={["w-3 shrink-0", entry.match && "text-emerald-400", !entry.match && "text-white/15"]}>
                    <%= if entry.match, do: "✓", else: "—" %>
                  </span>
                  <span class="w-52 shrink-0 text-white/25 truncate"><%= entry.filename %></span>
                  <span class="flex-1 text-white/40 truncate italic"><%= entry.subject %></span>
                  <%
                    score = entry.score
                    score_class = cond do
                      score >= 80 -> "text-emerald-400"
                      score >= 50 -> "text-yellow-400"
                      true        -> "text-white/25"
                    end
                  %>
                  <span class={["shrink-0 font-bold tabular-nums w-8 text-right", score_class]}>
                    <%= score %>
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Empty state links --%>
        <%= if @activity_log == [] and @status == :idle do %>
          <div class="mt-24 flex items-center gap-8 text-white/15">
            <div class="flex-1 h-px bg-white/5"></div>
            <.link navigate={~p"/gallery"} class="font-sans text-[10px] uppercase tracking-widest hover:text-white/40 transition-colors">
              View Archive →
            </.link>
            <div class="flex-1 h-px bg-white/5"></div>
          </div>
        <% end %>

      </div>
    </div>
    """
  end
end
