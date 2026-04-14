defmodule OrchestratorWeb.CuratorLive do
  use OrchestratorWeb, :live_view

  import Ecto.Query

  alias Orchestrator.Repo
  alias Orchestrator.Workers.LocalBatchImportWorker

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, "photo_updates")

    # Recover state if we reconnect mid-ingest — count both queues
    pending = Repo.aggregate(
      from(j in Oban.Job,
        where: j.queue in ["ai_jobs", "conversion"] and j.state in ["available", "executing", "retryable"]
      ),
      :count
    )

    # Backfill log from photos curated in the last 30 minutes
    cutoff = DateTime.utc_now() |> DateTime.add(-30 * 60, :second)
    recent = Repo.all(
      from p in Orchestrator.Photos.Photo,
        where: p.inserted_at >= ^cutoff and p.curation_status == "complete",
        order_by: [desc: p.inserted_at],
        limit: 100,
        select: %{
          filename: fragment("regexp_replace(?, '^.*/', '')", p.file_path),
          subject: p.subject,
          content_type: p.content_type
        }
    )

    activity_log = Enum.map(recent, fn r ->
      %{
        filename: r.filename || "",
        subject: r.subject || "—",
        content_type: r.content_type || "—"
      }
    end)

    socket =
      socket
      |> assign(:status, if(pending > 0, do: :ingesting, else: :idle))
      |> assign(:dir_path, "")
      |> assign(:sample, 50)
      |> assign(:project, "")
      |> assign(:import_queued, pending)
      |> assign(:import_processed, 0)
      |> assign(:import_failed_count, 0)
      |> assign(:import_error, nil)
      |> assign(:activity_log, activity_log)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("set_path", %{"dir_path" => path}, socket) do
    {:noreply, assign(socket, dir_path: path)}
  end

  @impl Phoenix.LiveView
  def handle_event("browse_directory", _params, socket) do
    case System.cmd("osascript", ["-e", ~s[POSIX path of (choose folder with prompt "Select a folder to ingest")]], stderr_to_stdout: false) do
      {path, 0} -> {:noreply, assign(socket, dir_path: String.trim(path, " /\n"))}
      _         -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("ingest", params, socket) do
    dir_path = params |> Map.get("dir_path", "") |> String.trim()
    project = params |> Map.get("project", "") |> String.trim()
    sample = case Integer.parse(Map.get(params, "sample", "50")) do
      {n, _} when n > 0 -> n
      _ -> 50
    end

    if dir_path != "" do
      %{"dir_path" => dir_path, "sample" => sample, "project" => project}
      |> LocalBatchImportWorker.new()
      |> Oban.insert()
    end

    {:noreply, assign(socket,
      status: if(dir_path != "", do: :ingesting, else: :idle),
      dir_path: dir_path,
      project: project,
      import_error: nil,
      import_queued: 0,
      import_processed: 0,
      import_failed_count: 0,
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
    {:noreply, assign(socket, status: :ingesting, import_queued: count, import_processed: 0)}
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
      content_type: metadata["content_type"] || "—"
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
  def handle_info({:curation_failed, _ref, basename, reason}, socket) do
    processed = socket.assigns.import_processed + 1
    failed_count = socket.assigns.import_failed_count + 1
    done = processed >= socket.assigns.import_queued and socket.assigns.import_queued > 0
    entry = %{
      filename: basename || "unknown",
      subject: reason || "curation failed",
      content_type: "—",
      status: :failed
    }
    log = [entry | socket.assigns.activity_log] |> Enum.take(100)
    {:noreply, socket
      |> assign(:activity_log, log)
      |> assign(:import_processed, processed)
      |> assign(:import_failed_count, failed_count)
      |> assign(:status, if(done, do: :done, else: :ingesting))}
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_skipped, _ref, _basename}, socket) do
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
    <div class="min-h-screen bg-[#fcfbf9] text-[#111111] font-serif selection:bg-[#111111] selection:text-[#fcfbf9]">

      <%!-- Header bar --%>
      <div class="border-b border-gray-200 px-8 py-4 flex items-center justify-between">
        <div>
          <span class="font-sans text-xs uppercase tracking-[0.4em] text-gray-400">fineshyt</span>
          <span class="font-sans text-xs text-gray-200 ml-3">·</span>
          <span class="font-sans text-xs uppercase tracking-widest text-gray-300 ml-3">archival system</span>
        </div>
        <div class="flex items-center gap-6">
          <.link navigate={~p"/projects"} class="font-sans text-xs uppercase tracking-widest text-gray-400 hover:text-gray-800 transition-colors border-b border-gray-300 hover:border-gray-800 pb-0.5">
            Projects
          </.link>
          <.link navigate={~p"/review"} class="font-sans text-xs uppercase tracking-widest text-gray-400 hover:text-gray-800 transition-colors border-b border-gray-300 hover:border-gray-800 pb-0.5">
            Review
          </.link>
          <.link navigate={~p"/gallery"} class="font-sans text-xs uppercase tracking-widest text-gray-400 hover:text-gray-800 transition-colors border-b border-gray-300 hover:border-gray-800 pb-0.5">
            Gallery →
          </.link>
        </div>
      </div>

      <div class="max-w-4xl mx-auto px-8 py-16">

        <%!-- Title --%>
        <div class="mb-16">
          <h1 class="text-[clamp(3rem,8vw,6rem)] font-black tracking-tight leading-none text-[#111111]">
            FINE.<br/>SHYT.
          </h1>
          <p class="mt-4 font-serif italic text-gray-400 text-lg">
            An algorithmic study of composition, light, and medium. Fine shyt if you will.
          </p>
        </div>

        <%!-- Main ingest form --%>
        <form phx-submit="ingest" class="mb-10">

          <%!-- Path input --%>
          <div class="mb-2">
            <label class="font-sans text-[10px] uppercase tracking-[0.35em] text-gray-400 block mb-3">
              Directory
            </label>
            <div class="flex gap-0 border border-gray-300 focus-within:border-[#111111] transition-colors">
              <span class="font-sans text-gray-300 text-sm px-4 flex items-center select-none border-r border-gray-200">
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
                class="flex-1 bg-transparent px-4 py-4 font-mono text-sm text-[#111111] placeholder-gray-300 focus:outline-none"
              />
              <%= if @dir_path != "" do %>
                <button
                  type="button"
                  phx-click="set_path"
                  phx-value-dir_path=""
                  class="px-4 text-gray-300 hover:text-gray-600 transition-colors font-sans text-sm border-l border-gray-200"
                >
                  ×
                </button>
              <% end %>
              <button
                type="button"
                phx-click="browse_directory"
                class="px-4 py-4 font-sans text-[10px] uppercase tracking-widest text-gray-400 hover:text-[#111111] border-l border-gray-200 hover:bg-gray-50 transition-colors shrink-0"
              >
                Browse
              </button>
            </div>
          </div>

          <%!-- Quick-access suggestions --%>
          <div class="flex gap-2 mb-8 flex-wrap">
            <%= for path <- ["/Volumes", "~/Desktop", "~/Downloads", "~/Pictures"] do %>
              <button
                type="button"
                phx-click="set_path"
                phx-value-dir_path={path}
                class="font-mono text-[10px] text-gray-400 border border-gray-200 px-2.5 py-1 hover:border-gray-500 hover:text-gray-700 transition-colors"
              >
                <%= path %>
              </button>
            <% end %>
          </div>

          <%!-- Secondary controls --%>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
            <div>
              <label class="font-sans text-[10px] uppercase tracking-[0.35em] text-gray-400 block mb-3">
                Project
              </label>
              <input
                type="text"
                name="project"
                value={@project}
                placeholder="e.g. 2024-film-roll-01"
                class="w-full border border-gray-300 focus:border-[#111111] px-4 py-3 font-mono text-xs text-gray-700 focus:outline-none transition-colors bg-transparent placeholder-gray-300"
              />
            </div>
            <div>
              <label class="font-sans text-[10px] uppercase tracking-[0.35em] text-gray-400 block mb-3">
                Sample Size
              </label>
              <input
                type="number"
                name="sample"
                value={@sample}
                min="1"
                max="500"
                class="w-full border border-gray-300 focus:border-[#111111] px-4 py-3 font-sans text-sm text-gray-700 focus:outline-none transition-colors bg-transparent"
              />
              <p class="mt-2 font-sans text-[9px] text-gray-400 leading-relaxed">
                Random sample from the directory. Larger sets take longer.
              </p>
            </div>
          </div>

          <%!-- Submit --%>
          <div class="flex items-center justify-between">
            <div>
              <%= if @import_error do %>
                <p class="font-sans text-xs text-red-700"><%= @import_error %></p>
              <% end %>
            </div>
            <%= if @status == :ingesting do %>
              <div class="flex items-center gap-4">
                <div class="flex items-center gap-2 font-sans text-xs text-gray-500">
                  <span class="w-1.5 h-1.5 bg-[#111111] rounded-full animate-ping inline-block"></span>
                  <%= @import_processed %> / <%= @import_queued %> processed
                </div>
                <button
                  type="button"
                  phx-click="stop"
                  class="font-sans text-xs uppercase tracking-widest text-red-700 border border-red-300 px-4 py-2 hover:border-red-700 transition-colors"
                >
                  Stop
                </button>
              </div>
            <% else %>
              <button
                type="submit"
                disabled={@dir_path == "" or @status == :ingesting}
                class="font-sans text-xs uppercase tracking-[0.3em] bg-[#111111] text-[#fcfbf9] px-10 py-3.5 hover:bg-gray-800 transition-colors disabled:opacity-30 disabled:cursor-not-allowed"
              >
                <%= if @status == :done, do: "Ingest Again →", else: "Ingest →" %>
              </button>
            <% end %>
          </div>
        </form>

        <%!-- Activity log --%>
        <%= if @activity_log != [] do %>
          <div class="border border-gray-200">
            <div class="flex items-center justify-between px-4 py-2.5 border-b border-gray-200 bg-gray-50">
              <span class="font-sans text-[10px] uppercase tracking-widest text-gray-500">
                <%= cond do %>
                  <% @status == :done and @import_failed_count > 0 -> %>
                    Done — <%= @import_processed - @import_failed_count %> curated · <span class="text-red-500"><%= @import_failed_count %> failed</span>
                  <% @status == :done -> %>
                    Done — <%= @import_processed %> curated
                  <% true -> %>
                    Processing...
                <% end %>
              </span>
              <button phx-click="clear_log" class="font-sans text-[10px] text-gray-400 hover:text-gray-700 uppercase tracking-widest transition-colors">
                Clear
              </button>
            </div>
            <div class="divide-y divide-gray-100 max-h-80 overflow-y-auto">
              <%= for entry <- @activity_log do %>
                <%= if Map.get(entry, :status) == :failed do %>
                  <div class="flex items-center gap-3 px-4 py-2 font-mono text-xs bg-red-50/50">
                    <span class="w-3 shrink-0 text-red-400">✗</span>
                    <span class="w-52 shrink-0 text-red-400 truncate"><%= entry.filename %></span>
                    <span class="flex-1 text-red-300 truncate italic"><%= entry.subject %></span>
                    <span class="shrink-0 font-sans text-[9px] uppercase tracking-wider text-red-300">failed</span>
                  </div>
                <% else %>
                  <div class="flex items-center gap-3 px-4 py-2 font-mono text-xs">
                    <span class="w-3 shrink-0 text-gray-300">·</span>
                    <span class="w-52 shrink-0 text-gray-400 truncate"><%= entry.filename %></span>
                    <span class="flex-1 text-gray-500 truncate italic"><%= entry.subject %></span>
                    <span class="shrink-0 font-sans text-[9px] uppercase tracking-wider text-gray-400">
                      <%= entry.content_type %>
                    </span>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Empty state links --%>
        <%= if @activity_log == [] and @status == :idle do %>
          <div class="mt-24 flex items-center gap-8 text-gray-300">
            <div class="flex-1 h-px bg-gray-200"></div>
            <.link navigate={~p"/gallery"} class="font-sans text-[10px] uppercase tracking-widest hover:text-gray-600 transition-colors">
              View Archive →
            </.link>
            <div class="flex-1 h-px bg-gray-200"></div>
          </div>
        <% end %>

      </div>
    </div>
    """
  end
end
