defmodule OrchestratorWeb.ReviewLive do
  @moduledoc """
  Loupe view — single image, keyboard-driven, photographer-style culling
  and rating workflow at `/review`.

  Modeled on Adobe Lightroom's loupe view: one image fills the screen,
  keys decide its fate, the cursor advances. Two distinct passes are
  expressed as URL-controllable modes:

    * `:cull` — only photos with no rating yet, oldest first. Pass 1.
    * `:rate` — rated photos sorted by rating ascending so borderline
      1★/2★ shots get re-examined first. Pass 2.

  ## State

    * `:queue` — list of `%Photo{}` loaded once on mount via
      `Photos.list_cull_queue/1` or `Photos.list_rate_queue/1`.
    * `:index` — 0-based pointer into the queue.
    * `:mode` — `:cull` | `:rate`.
    * `:projects` — string list for the project chip selector.
    * `:project_input` — buffered text for the new-project input.
    * `:cull_count`, `:rated_count` — header badges.
    * `:tag_profile` — affinity map from `Photos.tag_affinity_profile/0`.
    * `:show_help` — boolean toggling the help overlay.
    * `:flash_msg` — transient string ("★ 5", "rejected", ...).

  Each decision patches that photo's row in the queue in place so the UI
  stays consistent if the user navigates back. Rejection is the exception:
  the rejected entry is *removed* from the queue so the cursor lands on
  the next photo without an extra keystroke. When the queue empties an
  "all done" state is shown.

  ## Keyboard

  See the help overlay (toggle with `?`) for the full list. Most-used:
  `←/→` navigate, `1`–`5` rate-and-advance, `p` pick (★5), `x` reject,
  `u`/`0` clear rating, `space` advance.
  """

  use OrchestratorWeb, :live_view

  alias Orchestrator.Photos

  @doc """
  LiveView mount. Reads `mode` from URL params, loads the matching queue,
  primes the side panel data (projects, counts, tag profile) and resets
  the cursor.

  ## Parameters

    * `params` — URL params; `"mode"` may be `"cull"` (default) or `"rate"`.
    * `_session` — unused.
    * `socket` — the LiveView socket.

  ## Returns

    * `{:ok, socket}` with all assigns populated.
  """
  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    mode = parse_mode(params["mode"])

    {queue, projects} = {load_queue(mode), Photos.list_projects()}

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:queue, queue)
      |> assign(:index, 0)
      |> assign(:project_input, "")
      |> assign(:projects, projects)
      |> assign(:show_help, false)
      |> assign(:cull_count, Photos.count_pending_cull())
      |> assign(:rated_count, Photos.count_rated())
      |> assign(:tag_profile, Photos.tag_affinity_profile())
      |> assign(:flash_msg, nil)

    {:ok, socket}
  end

  defp parse_mode("rate"), do: :rate
  defp parse_mode(_), do: :cull

  defp load_queue(:cull), do: Photos.list_cull_queue()
  defp load_queue(:rate), do: Photos.list_rate_queue()

  defp current(%{queue: queue, index: index}), do: Enum.at(queue, index)

  # ── keyboard ──────────────────────────────────────────────────────────────

  @doc """
  Dispatch every event raised by the loupe view.

  Bound through `phx-window-keydown="key"` (the `"key"` event), `phx-click`
  on the side panel and overlay buttons, and `phx-submit` on the
  new-project form.

  ## Events

    * `"key"` — keyboard input. Recognized:
      `ArrowLeft` / `ArrowRight` / `Space` (navigate),
      `1`–`5` (rate in place),
      `p` / `P` (pick: rate ★5 in place),
      `u` / `U` / `0` (clear rating),
      `x` / `X` (soft-reject and remove from queue — advances cursor),
      `?` (toggle help),
      `Escape` (close help). Unrecognized keys are ignored.

    * `"nav"` — `%{"dir" => "next" | "prev"}`. Click zones on left/right
      of the image.

    * `"rate"` — `%{"value" => "1".."5"}`. Star strip click; rates in
      place without advancing so the highlight is visible. Empty values
      are ignored (defensive — see `parse_rating/1`).

    * `"reject"` — bottom-bar reject button (mirror of `x`).

    * `"unrate"` — bottom-bar clear button.

    * `"toggle_help"` / `"set_mode"` — header buttons.
      `"set_mode"` reloads the queue for the new mode and resets index to 0.

    * `"project_input"` — change event on the new-project input field.

    * `"set_project"` — `%{"name" => name}`. Project chip click; assigns
      that name to the current photo and refreshes the project list.

    * `"clear_project"` — bottom-bar clear-project button.

    * `"save_project_input"` — form submit; equivalent to `set_project`
      with the buffered input value.

  ## Returns

    * `{:noreply, socket}` — every clause; the view never replies.
  """
  @impl Phoenix.LiveView
  def handle_event("key", %{"key" => key}, socket) do
    case key do
      "ArrowRight" -> {:noreply, advance(socket, +1)}
      "ArrowLeft"  -> {:noreply, advance(socket, -1)}
      " "          -> {:noreply, advance(socket, +1)}
      k when k in ~w(x X) -> {:noreply, reject_current(socket)}
      k when k in ~w(p P) -> {:noreply, rate_current(socket, 5)}
      k when k in ~w(u U 0) -> {:noreply, unrate_current(socket)}
      k when k in ~w(1 2 3 4 5) ->
        {:noreply, rate_current(socket, String.to_integer(k))}
      "?"          -> {:noreply, assign(socket, :show_help, !socket.assigns.show_help)}
      "Escape"     -> {:noreply, assign(socket, :show_help, false)}
      _            -> {:noreply, socket}
    end
  end

  def handle_event("nav", %{"dir" => "next"}, socket), do: {:noreply, advance(socket, +1)}
  def handle_event("nav", %{"dir" => "prev"}, socket), do: {:noreply, advance(socket, -1)}

  def handle_event("rate", %{"value" => v}, socket) do
    case parse_rating(v) do
      nil -> {:noreply, socket}
      n -> {:noreply, rate_current(socket, n)}
    end
  end

  def handle_event("reject", _, socket), do: {:noreply, reject_current(socket)}
  def handle_event("unrate", _, socket), do: {:noreply, unrate_current(socket)}

  def handle_event("toggle_help", _, socket), do: {:noreply, assign(socket, :show_help, !socket.assigns.show_help)}

  def handle_event("set_mode", %{"mode" => m}, socket) do
    mode = parse_mode(m)
    {:noreply,
     socket
     |> assign(:mode, mode)
     |> assign(:queue, load_queue(mode))
     |> assign(:index, 0)
     |> assign(:flash_msg, nil)}
  end

  def handle_event("project_input", %{"value" => v}, socket) do
    {:noreply, assign(socket, :project_input, v)}
  end

  def handle_event("set_project", %{"name" => name}, socket) do
    case current(socket.assigns) do
      nil -> {:noreply, socket}
      photo ->
        case Photos.set_project(photo.id, name) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> patch_current(updated)
             |> assign(:project_input, "")
             |> assign(:projects, Photos.list_projects())
             |> flash_for("→ #{name}")}

          _ ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("clear_project", _, socket) do
    case current(socket.assigns) do
      nil -> {:noreply, socket}
      photo ->
        {:ok, updated} = Photos.set_project(photo.id, "")
        {:noreply, socket |> patch_current(updated) |> flash_for("project cleared")}
    end
  end

  def handle_event("save_project_input", _, socket) do
    name = String.trim(socket.assigns.project_input)
    if name == "", do: {:noreply, socket}, else: handle_event("set_project", %{"name" => name}, socket)
  end

  # ── decision helpers ──────────────────────────────────────────────────────

  defp parse_rating(v) when is_integer(v) and v in 1..5, do: v
  defp parse_rating(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n in 1..5 -> n
      _ -> nil
    end
  end
  defp parse_rating(_), do: nil

  defp rate_current(socket, value) do
    case current(socket.assigns) do
      nil -> socket
      photo ->
        case Photos.rate_photo(photo.id, value) do
          {:ok, updated} ->
            trigger_preference_retrain()
            socket |> patch_current(updated) |> flash_for("★ #{value}")

          _ ->
            socket
        end
    end
  end

  # Debounced retrain — Oban unique job collapses a burst of ratings into
  # a single PreferenceTrainWorker run within any 5-minute window.
  defp trigger_preference_retrain do
    Orchestrator.Workers.PreferenceTrainWorker.new(%{trigger: "rating_change"})
    |> Oban.insert()
  end

  defp unrate_current(socket) do
    case current(socket.assigns) do
      nil -> socket
      photo ->
        case Photos.override_curation(photo.id, %{user_rating: nil}) do
          {:ok, updated} -> socket |> patch_current(updated) |> flash_for("rating cleared")
          _ -> socket
        end
    end
  end

  defp reject_current(socket) do
    case current(socket.assigns) do
      nil ->
        socket

      photo ->
        {:ok, _} = Photos.reject_photo(photo.id)
        # Remove from queue at current index. After removal, the same index
        # already points at what was the next photo, so no advance() is needed.
        # Clamp to last item if we just removed the tail.
        new_queue = List.delete_at(socket.assigns.queue, socket.assigns.index)
        new_index = min(socket.assigns.index, max(length(new_queue) - 1, 0))

        socket
        |> assign(:queue, new_queue)
        |> assign(:index, new_index)
        |> assign(:cull_count, Photos.count_pending_cull())
        |> flash_for("rejected")
    end
  end

  defp patch_current(socket, updated_photo) do
    queue = List.replace_at(socket.assigns.queue, socket.assigns.index, updated_photo)

    socket
    |> assign(:queue, queue)
    |> assign(:cull_count, Photos.count_pending_cull())
    |> assign(:rated_count, Photos.count_rated())
  end

  defp advance(socket, delta) do
    len = length(socket.assigns.queue)

    if len == 0 do
      assign(socket, :index, 0)
    else
      next = socket.assigns.index + delta
      next = next |> max(0) |> min(len - 1)
      assign(socket, :index, next)
    end
  end

  defp flash_for(socket, msg), do: assign(socket, :flash_msg, msg)

  # ── render ────────────────────────────────────────────────────────────────

  @doc """
  Render the loupe view template.

  Dark theme (`bg-[#0f0f0f] text-[#fcfbf9]`), three regions: header bar
  with mode tabs and counts, the centerpiece image with click zones and
  star strip, and the metadata side panel (subject / mood / lighting /
  tags / project assignment). Help overlay is conditional on `@show_help`.

  ## Parameters

    * `assigns` — the LiveView assigns map.

  ## Returns

    * `Phoenix.LiveView.Rendered.t()` — the HEEx template.
  """
  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div
      id="review-root"
      class="min-h-screen bg-[#0f0f0f] text-[#fcfbf9] font-serif select-none"
      phx-window-keydown="key"
    >
      <%!-- Top bar --%>
      <header class="border-b border-gray-800 px-6 py-3 flex items-center gap-6">
        <.link navigate={~p"/gallery"} class="font-sans text-[10px] uppercase tracking-widest text-gray-500 hover:text-gray-200 transition-colors">
          ← Gallery
        </.link>
        <span class="font-sans text-[10px] uppercase tracking-widest text-gray-600">/</span>
        <h1 class="font-sans text-[10px] uppercase tracking-[0.3em] text-gray-300">Review</h1>

        <div class="flex gap-1">
          <button
            phx-click="set_mode"
            phx-value-mode="cull"
            class={[
              "font-sans text-[10px] uppercase tracking-wider px-3 py-1 border transition-colors",
              @mode == :cull && "border-[#fcfbf9] text-[#fcfbf9]",
              @mode != :cull && "border-gray-700 text-gray-500 hover:border-gray-500 hover:text-gray-300"
            ]}
          >Cull · <%= @cull_count %></button>
          <button
            phx-click="set_mode"
            phx-value-mode="rate"
            class={[
              "font-sans text-[10px] uppercase tracking-wider px-3 py-1 border transition-colors",
              @mode == :rate && "border-[#fcfbf9] text-[#fcfbf9]",
              @mode != :rate && "border-gray-700 text-gray-500 hover:border-gray-500 hover:text-gray-300"
            ]}
          >Rate · <%= @rated_count %></button>
        </div>

        <div class="flex-1"></div>

        <%= if @queue != [] do %>
          <span class="font-mono text-[11px] text-gray-500 tabular-nums">
            <%= @index + 1 %> / <%= length(@queue) %>
          </span>
        <% end %>

        <button
          phx-click="toggle_help"
          class="font-sans text-[10px] uppercase tracking-widest text-gray-500 hover:text-gray-200 transition-colors border border-gray-700 hover:border-gray-400 px-2 py-1"
        >?</button>
      </header>

      <%= if @queue == [] do %>
        <div class="flex flex-col items-center justify-center" style="height: calc(100vh - 60px);">
          <p class="font-serif italic text-gray-500 text-2xl mb-2">
            <%= if @mode == :cull, do: "Cull queue is empty.", else: "Nothing to rate yet." %>
          </p>
          <p class="font-sans text-[11px] uppercase tracking-widest text-gray-700">
            <%= if @mode == :cull, do: "Beautiful. Switch to Rate mode or head back to the gallery.", else: "Cull some photos first." %>
          </p>
        </div>
      <% else %>
        <% photo = current(assigns) %>

        <div class="grid grid-cols-1 lg:grid-cols-[1fr_320px]" style="height: calc(100vh - 60px);">
          <%!-- Image stage --%>
          <div class="relative bg-[#0f0f0f] flex items-center justify-center overflow-hidden">
            <%= if photo.url do %>
              <img
                src={photo.url}
                alt={photo.subject || "photo"}
                class="max-w-full max-h-full object-contain"
                style="max-height: calc(100vh - 80px);"
              />
            <% else %>
              <div class="text-gray-700 font-mono text-sm">no image</div>
            <% end %>

            <%!-- Floating filename + flash --%>
            <div class="absolute top-4 left-4 right-4 flex items-start justify-between gap-4 pointer-events-none">
              <p class="font-mono text-[10px] text-gray-600 truncate max-w-[60%]">
                <%= Path.basename(photo.file_path || "") %>
              </p>
              <%= if @flash_msg do %>
                <p class="font-sans text-[11px] uppercase tracking-widest text-[#fcfbf9] bg-[#111111]/90 border border-gray-700 px-2 py-1">
                  <%= @flash_msg %>
                </p>
              <% end %>
            </div>

            <%!-- Click zones for prev/next --%>
            <button
              phx-click="nav"
              phx-value-dir="prev"
              class="absolute left-0 top-0 bottom-0 w-1/4 cursor-w-resize opacity-0 hover:opacity-100 transition-opacity flex items-center justify-start pl-4"
              aria-label="previous"
            >
              <span class="font-sans text-3xl text-[#fcfbf9]/60">‹</span>
            </button>
            <button
              phx-click="nav"
              phx-value-dir="next"
              class="absolute right-0 top-0 bottom-0 w-1/4 cursor-e-resize opacity-0 hover:opacity-100 transition-opacity flex items-center justify-end pr-4"
              aria-label="next"
            >
              <span class="font-sans text-3xl text-[#fcfbf9]/60">›</span>
            </button>

            <%!-- Bottom action bar --%>
            <div class="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-[#0f0f0f] via-[#0f0f0f]/80 to-transparent px-6 py-4 flex items-center justify-center gap-3">
              <%!-- Star strip --%>
              <div class="flex items-center gap-1 mr-4">
                <%= for star <- 1..5 do %>
                  <button
                    phx-click="rate"
                    phx-value-value={star}
                    class={[
                      "text-2xl leading-none transition-colors",
                      photo.user_rating && photo.user_rating >= star && "text-[#fcfbf9]",
                      !(photo.user_rating && photo.user_rating >= star) && "text-gray-700 hover:text-gray-400"
                    ]}
                  >★</button>
                <% end %>
                <%= if photo.user_rating do %>
                  <button
                    phx-click="unrate"
                    title="clear rating"
                    class="ml-2 font-sans text-[9px] uppercase tracking-widest text-gray-600 hover:text-gray-300 transition-colors"
                  >clear</button>
                <% end %>
              </div>

              <button
                phx-click="reject"
                class="font-sans text-[10px] uppercase tracking-widest text-red-400 border border-red-900 hover:border-red-500 hover:text-red-300 px-3 py-1.5 transition-colors"
              >× reject</button>
            </div>
          </div>

          <%!-- Side panel --%>
          <aside class="border-l border-gray-800 bg-[#0c0c0c] overflow-y-auto">
            <div class="p-6 space-y-6">

              <%!-- Subject + critique --%>
              <div>
                <p class="font-sans text-[9px] uppercase tracking-widest text-gray-600 mb-1">Subject</p>
                <p class="font-serif text-base text-[#fcfbf9] leading-snug"><%= photo.subject || "—" %></p>
              </div>

              <%= if photo.artistic_mood do %>
                <div>
                  <p class="font-sans text-[9px] uppercase tracking-widest text-gray-600 mb-1">Mood</p>
                  <p class="font-serif italic text-sm text-gray-300"><%= photo.artistic_mood %></p>
                </div>
              <% end %>

              <%= if photo.lighting_critique do %>
                <div>
                  <p class="font-sans text-[9px] uppercase tracking-widest text-gray-600 mb-1">Light</p>
                  <p class="font-serif italic text-sm text-gray-400 leading-snug"><%= photo.lighting_critique %></p>
                </div>
              <% end %>

              <%= if photo.style_score do %>
                <div>
                  <p class="font-sans text-[9px] uppercase tracking-widest text-gray-600 mb-1">Style score</p>
                  <p class="font-mono text-sm text-gray-300"><%= photo.style_score %><span class="text-gray-700"> / 100</span></p>
                </div>
              <% end %>

              <%= if photo.suggested_tags && photo.suggested_tags != [] do %>
                <div>
                  <p class="font-sans text-[9px] uppercase tracking-widest text-gray-600 mb-2">Tags</p>
                  <div class="flex flex-wrap gap-1">
                    <%= for tag <- photo.suggested_tags do %>
                      <span class="font-sans text-[10px] uppercase tracking-wider text-gray-400 border border-gray-700 px-2 py-0.5">
                        <%= String.downcase(tag) %>
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Project --%>
              <div>
                <p class="font-sans text-[9px] uppercase tracking-widest text-gray-600 mb-2">Project</p>
                <%= if photo.project && photo.project != "" do %>
                  <div class="flex items-center gap-2 mb-2">
                    <span class="font-mono text-[11px] text-[#fcfbf9] border border-gray-600 px-2 py-1"><%= photo.project %></span>
                    <button
                      phx-click="clear_project"
                      class="font-sans text-[9px] uppercase tracking-widest text-gray-600 hover:text-red-400 transition-colors"
                    >clear</button>
                  </div>
                <% end %>

                <%= if @projects != [] do %>
                  <div class="flex flex-wrap gap-1 mb-3">
                    <%= for proj <- @projects do %>
                      <button
                        phx-click="set_project"
                        phx-value-name={proj}
                        class={[
                          "font-mono text-[10px] px-2 py-0.5 border transition-colors",
                          photo.project == proj && "border-[#fcfbf9] text-[#fcfbf9]",
                          photo.project != proj && "border-gray-700 text-gray-500 hover:border-gray-500 hover:text-gray-300"
                        ]}
                      ><%= proj %></button>
                    <% end %>
                  </div>
                <% end %>

                <form phx-submit="save_project_input" class="flex gap-1">
                  <input
                    type="text"
                    name="value"
                    value={@project_input}
                    phx-change="project_input"
                    phx-debounce="200"
                    placeholder="new project…"
                    class="flex-1 bg-transparent border border-gray-700 focus:border-gray-400 px-2 py-1 font-mono text-[11px] text-gray-300 placeholder-gray-700 focus:outline-none"
                  />
                  <button type="submit" class="font-sans text-[9px] uppercase tracking-widest text-gray-500 border border-gray-700 hover:border-gray-400 hover:text-gray-200 px-2 py-1 transition-colors">set</button>
                </form>
              </div>

            </div>
          </aside>
        </div>
      <% end %>

      <%!-- Help overlay --%>
      <%= if @show_help do %>
        <div
          phx-click="toggle_help"
          class="fixed inset-0 bg-[#0f0f0f]/95 z-50 flex items-center justify-center"
        >
          <div class="border border-gray-800 bg-[#0c0c0c] p-8 max-w-md font-mono text-[11px] text-gray-300">
            <p class="font-sans text-[10px] uppercase tracking-widest text-gray-500 mb-4">Keyboard</p>
            <table class="w-full">
              <tbody class="space-y-1">
                <tr><td class="text-gray-500 pr-6">← →</td><td>previous / next</td></tr>
                <tr><td class="text-gray-500 pr-6">space</td><td>next</td></tr>
                <tr><td class="text-gray-500 pr-6">1–5</td><td>rate</td></tr>
                <tr><td class="text-gray-500 pr-6">p</td><td>pick (= ★★★★★)</td></tr>
                <tr><td class="text-gray-500 pr-6">u, 0</td><td>clear rating</td></tr>
                <tr><td class="text-gray-500 pr-6">x</td><td>reject (soft, reversible)</td></tr>
                <tr><td class="text-gray-500 pr-6">?</td><td>show / hide this</td></tr>
                <tr><td class="text-gray-500 pr-6">esc</td><td>close help</td></tr>
              </tbody>
            </table>
            <p class="mt-6 text-[10px] text-gray-600 italic">click anywhere to close</p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
