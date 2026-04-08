defmodule OrchestratorWeb.LogsLive do
  @moduledoc """
  Dev-only error log viewer at `/logs`.

  Subscribes to the `Orchestrator.ErrorLog` PubSub topic so worker
  failures appear in real time without polling, and backfills the page on
  mount with the latest 500 rows from the `error_logs` table.

  ## State

    * `:entries` — list of `%Orchestrator.ErrorLog{}`, newest first,
      capped at 500 in memory regardless of how many sit in the DB.
    * `:total` — running count of all rows ever recorded since last clear.
    * `:expanded` — `MapSet` of error ids currently expanded to show
      pretty-printed JSON detail.
    * `:worker_filter` — `:all`, `:ai`, or `:conversion`.

  ## PubSub messages handled

    * `{:error_logged, entry}` — new error: prepend and trim to 500.
    * `:error_log_cleared` — wipe the in-memory list.

  Intended strictly for development; the route is not protected and the
  detail payload may contain stack traces and request bodies.
  """

  use OrchestratorWeb, :live_view

  alias Orchestrator.ErrorLog

  @doc """
  LiveView mount. Subscribes to the ErrorLog PubSub topic and backfills
  the latest 500 rows.

  ## Parameters

    * `_params`, `_session` — unused.
    * `socket` — the LiveView socket.

  ## Returns

    * `{:ok, socket}` with `:entries`, `:total`, `:expanded`, and
      `:worker_filter` populated.
  """
  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, ErrorLog.topic())

    {:ok,
     socket
     |> assign(:entries, ErrorLog.list(500))
     |> assign(:total, ErrorLog.count())
     |> assign(:expanded, MapSet.new())
     |> assign(:worker_filter, :all)}
  end

  @doc """
  Handle PubSub messages from `Orchestrator.ErrorLog`.

  ## Messages

    * `{:error_logged, %ErrorLog{}}` — a new error was recorded.
      Prepended to `:entries` and the in-memory list is trimmed to 500;
      `:total` increments by one.
    * `:error_log_cleared` — the user clicked Clear (or `ErrorLog.clear/0`
      ran). Wipes `:entries`, `:total`, and `:expanded`.
    * Anything else — ignored.

  ## Returns

    * `{:noreply, socket}`
  """
  @impl Phoenix.LiveView
  def handle_info({:error_logged, entry}, socket) do
    entries = [entry | socket.assigns.entries] |> Enum.take(500)
    {:noreply, socket |> assign(:entries, entries) |> assign(:total, socket.assigns.total + 1)}
  end

  def handle_info(:error_log_cleared, socket) do
    {:noreply, socket |> assign(:entries, []) |> assign(:total, 0) |> assign(:expanded, MapSet.new())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @doc """
  Dispatch UI events from the logs page.

  ## Events

    * `"clear"` — header Clear button. Calls `ErrorLog.clear/0`; the
      resulting PubSub broadcast then wipes the local state.
    * `"toggle"` — `%{"id" => id}`. Click on a row to expand or collapse
      its detail block.
    * `"filter"` — `%{"worker" => name}`. Switch between All / AI Curation
      / Conversion tabs. Unknown worker names fall through to `:all`.

  ## Returns

    * `{:noreply, socket}`
  """
  @impl Phoenix.LiveView
  def handle_event("clear", _params, socket) do
    ErrorLog.clear()
    {:noreply, socket}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, id),
        do: MapSet.delete(expanded, id),
        else: MapSet.put(expanded, id)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("filter", %{"worker" => worker}, socket) do
    atom =
      case worker do
        "AiCurationWorker" -> :ai
        "ConversionWorker" -> :conversion
        _ -> :all
      end

    {:noreply, assign(socket, :worker_filter, atom)}
  end

  defp visible_entries(entries, :all), do: entries
  defp visible_entries(entries, :ai), do: Enum.filter(entries, &(&1.worker == "AiCurationWorker"))
  defp visible_entries(entries, :conversion), do: Enum.filter(entries, &(&1.worker == "ConversionWorker"))

  defp format_at(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_at(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_at(_), do: "—"

  defp pretty_detail(nil), do: "(no detail)"

  defp pretty_detail(detail) do
    case Jason.encode(detail, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(detail, pretty: true, limit: :infinity)
    end
  end

  defp status_class(nil), do: "text-gray-400 border-gray-300"
  defp status_class(s) when s >= 500, do: "text-red-700 border-red-400"
  defp status_class(s) when s >= 400, do: "text-amber-700 border-amber-400"
  defp status_class(_), do: "text-gray-500 border-gray-300"

  @doc """
  Render the error log table.

  Light theme matching the gallery's serif aesthetic. Header shows the
  total count and worker filter tabs; rows are color-coded by HTTP status
  via `status_class/1` (4xx amber, 5xx red); expanded rows pretty-print
  the JSON `detail` payload.

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
          <h1 class="text-6xl md:text-8xl font-black tracking-tight leading-none">ERROR<br/>LOG.</h1>
          <p class="mt-4 text-lg font-light italic text-gray-600">
            Worker failures, freshest first.
            <span class="font-sans text-sm not-italic text-gray-400">
              showing <%= length(@entries) %> of <%= @total %> persisted
            </span>
          </p>
        </div>
        <div class="mt-6 md:mt-0 font-sans uppercase tracking-widest text-xs flex gap-6">
          <.link navigate={~p"/"} class="border-b border-gray-400 pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors">
            Ingest
          </.link>
          <.link navigate={~p"/gallery"} class="border-b border-gray-400 pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors">
            Gallery
          </.link>
        </div>
      </header>

      <%!-- Filter + actions --%>
      <div class="flex items-center gap-2 mb-8 flex-wrap">
        <span class="font-sans text-[9px] uppercase tracking-widest text-gray-400 shrink-0">Worker</span>
        <%= for {label, value, atom} <- [
          {"All", "all", :all},
          {"AI Curation", "AiCurationWorker", :ai},
          {"Conversion", "ConversionWorker", :conversion}
        ] do %>
          <button
            phx-click="filter"
            phx-value-worker={value}
            class={[
              "font-sans text-[10px] uppercase tracking-wider px-3 py-1 border transition-colors",
              @worker_filter == atom && "border-[#111111] text-[#111111]",
              @worker_filter != atom && "border-gray-200 text-gray-400 hover:border-gray-500 hover:text-gray-700"
            ]}
          ><%= label %></button>
        <% end %>
        <div class="flex-1"></div>
        <button
          phx-click="clear"
          data-confirm="Clear all error log entries?"
          class="font-sans text-[10px] uppercase tracking-widest text-red-700 border border-red-300 px-3 py-1.5 hover:border-red-600 transition-colors"
        >Clear</button>
      </div>

      <% visible = visible_entries(@entries, @worker_filter) %>

      <%= if visible == [] do %>
        <div class="text-center py-24 text-gray-400 font-serif italic text-xl">
          No errors recorded. Beautiful.
        </div>
      <% else %>
        <ul class="space-y-3">
          <%= for entry <- visible do %>
            <% expanded? = MapSet.member?(@expanded, entry.id) %>
            <li class="border border-gray-200 bg-white">
              <button
                phx-click="toggle"
                phx-value-id={entry.id}
                class="w-full text-left px-4 py-3 flex items-start gap-4 hover:bg-gray-50 transition-colors"
              >
                <span class="font-mono text-[10px] text-gray-400 shrink-0 mt-1 tabular-nums">
                  <%= format_at(entry.inserted_at) %>
                </span>
                <span class="font-sans text-[10px] uppercase tracking-wider text-gray-600 border border-gray-300 px-2 py-0.5 shrink-0 mt-0.5">
                  <%= entry.worker %>
                </span>
                <%= if entry.status do %>
                  <span class={[
                    "font-mono text-[10px] uppercase tracking-wider px-2 py-0.5 border shrink-0 mt-0.5",
                    status_class(entry.status)
                  ]}>
                    <%= entry.status %>
                  </span>
                <% end %>
                <%= if entry.attempt && entry.max_attempts do %>
                  <span class="font-mono text-[10px] text-gray-400 shrink-0 mt-0.5">
                    <%= entry.attempt %>/<%= entry.max_attempts %>
                  </span>
                <% end %>
                <span class="flex-1 min-w-0">
                  <%= if entry.file do %>
                    <span class="font-mono text-[11px] text-gray-700 mr-2"><%= entry.file %></span>
                  <% end %>
                  <span class="font-sans text-[12px] text-[#111111] break-words"><%= entry.reason %></span>
                </span>
                <span class="font-sans text-[9px] uppercase tracking-widest text-gray-400 shrink-0 mt-1">
                  <%= if expanded?, do: "−", else: "+" %>
                </span>
              </button>

              <%= if expanded? do %>
                <div class="border-t border-gray-200 bg-gray-50 px-4 py-3">
                  <p class="font-sans text-[9px] uppercase tracking-widest text-gray-400 mb-2">Detail</p>
                  <pre class="font-mono text-[11px] text-gray-700 whitespace-pre-wrap break-words leading-snug"><%= pretty_detail(entry.detail) %></pre>
                </div>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end
end
