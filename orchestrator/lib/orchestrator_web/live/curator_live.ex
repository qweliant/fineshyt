defmodule OrchestratorWeb.CuratorLive do
  use OrchestratorWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orchestrator.PubSub, "photo_updates")

    socket =
      socket
      |> assign(:uploaded_files, [])
      |> assign(:metadata, nil)
      |> assign(:status, :idle) # States: :idle, :uploading, :processing, :complete, :failed
      |> allow_upload(:photo, accept: ~w(.jpg .jpeg .png), max_entries: 1, max_file_size: 10_000_000)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("reset", _params, socket) do
    {:noreply, assign(socket, status: :idle, metadata: nil, uploaded_files: [])}
  end

  @impl Phoenix.LiveView
  def handle_event("save", _params, socket) do
    socket = assign(socket, status: :processing, metadata: nil)

    uploaded_files =
      consume_uploaded_entries(socket, :photo, fn %{path: path}, entry ->
        dest = Path.join([:code.priv_dir(:orchestrator), "static", "uploads", entry.client_name])
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(path, dest)

        ref = make_ref() |> inspect()

        %{file_path: dest, ref: ref}
        |> Orchestrator.Workers.AiCurationWorker.new()
        |> Oban.insert()

        {:ok, %{url: "/uploads/#{entry.client_name}", ref: ref}}
      end)

    {:noreply, assign(socket, uploaded_files: uploaded_files)}
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_complete, ref, metadata, _basename}, socket) do
    case Enum.find(socket.assigns.uploaded_files, &(&1.ref == ref)) do
      nil -> {:noreply, socket}
      _ -> {:noreply, assign(socket, metadata: metadata, status: :complete)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:curation_failed, ref, _reason}, socket) do
    case Enum.find(socket.assigns.uploaded_files, &(&1.ref == ref)) do
      nil -> {:noreply, socket}
      _ -> {:noreply, assign(socket, status: :failed)}
    end
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  defp upload_error_to_string(:too_large), do: "File exceeds 10MB limit."
  defp upload_error_to_string(:not_accepted), do: "Only .jpg, .jpeg, and .png files are accepted."
  defp upload_error_to_string(:too_many_files), do: "Only one file at a time."
  defp upload_error_to_string(_), do: "Upload failed. Please try again."

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <%!-- The Canvas: Off-white paper background, stark text, serif fonts --%>
    <div class="min-h-screen bg-[#fcfbf9] text-[#111111] font-serif selection:bg-[#111111] selection:text-[#fcfbf9] p-6 md:p-12 lg:p-24">

      <%!-- Editorial Header --%>
      <header class="mb-16 border-b-[3px] border-[#111111] pb-6 flex flex-col md:flex-row md:items-end justify-between">
        <div>
          <h1 class="text-6xl md:text-8xl font-black tracking-tight leading-none">FINE.<br/>SHYT.</h1>
          <p class="mt-4 text-lg md:text-xl font-light italic text-gray-600 max-w-xl">
            An algorithmic study of composition, light, and medium. Fine shyt if you will.
          </p>
        </div>
        <div class="mt-6 md:mt-0 text-right uppercase tracking-widest text-xs font-sans font-bold">
          <p>Edition No. 001</p>
          <p class="text-gray-500">Autonomous Archival System</p>
          <a href="/gallery" class="mt-3 inline-block border-b border-[#111111] pb-0.5 hover:text-gray-500 hover:border-gray-500 transition-colors">
            View Gallery →
          </a>
        </div>
      </header>

      <div class="grid grid-cols-1 lg:grid-cols-12 gap-12 lg:gap-24">

        <%!-- Left Column: The Interactive Canvas --%>
        <div class="lg:col-span-7 relative">

          <form id="upload-form" phx-submit="save" phx-change="validate" class="h-full">
            <div
              class={[
                "relative w-full aspect-square md:aspect-[4/3] flex flex-col items-center justify-center border border-[#111111] bg-[#fcfbf9] transition-all duration-700 ease-in-out group",
                @status == :idle && "hover:bg-[#111111] hover:text-[#fcfbf9] cursor-pointer"
              ]}
              phx-drop-target={@uploads.photo.ref}
            >

              <%!-- Upload Input --%>
              <.live_file_input upload={@uploads.photo} class="hidden" />

              <%!-- State: Idle --%>
              <%= if @status == :idle and @uploads.photo.entries == [] do %>
                <label for={@uploads.photo.ref} class="absolute inset-0 w-full h-full cursor-pointer flex flex-col items-center justify-center z-10">
                  <span class="uppercase tracking-[0.3em] text-sm font-sans mb-2">Drop Photograph</span>
                  <span class="font-serif italic text-gray-400 group-hover:text-gray-300">or click to open archives</span>
                  <span class="absolute bottom-6 left-6 text-xs font-sans uppercase tracking-widest text-gray-400">Accepts botanical, macabre, or structural studies.</span>
                </label>
              <% end %>

              <%!-- Upload Errors --%>
              <%= for entry <- @uploads.photo.entries do %>
                <%= for err <- upload_errors(@uploads.photo, entry) do %>
                  <div class="absolute bottom-4 left-4 right-4 bg-[#fcfbf9] border border-red-800 px-4 py-2 z-20">
                    <span class="font-sans uppercase tracking-widest text-xs text-red-800">
                      <%= upload_error_to_string(err) %>
                    </span>
                  </div>
                <% end %>
              <% end %>

              <%!-- State: Image Selected / Processing / Complete --%>
              <%= if @uploads.photo.entries != [] or @uploaded_files != [] do %>
                <div class="absolute inset-4 overflow-hidden border border-gray-200 bg-white shadow-2xl">
                  <%= if @uploads.photo.entries != [] do %>
                    <.live_img_preview
                      entry={hd(@uploads.photo.entries)}
                      class="object-cover w-full h-full"
                    />
                  <% else %>
                    <img
                      src={hd(@uploaded_files).url}
                      class={[
                        "object-cover w-full h-full transition-all duration-[3000ms] ease-out",
                        @status == :processing && "grayscale contrast-125 brightness-90 animate-pulse scale-105",
                        @status == :failed && "grayscale brightness-50 scale-100",
                        @status == :complete && "grayscale-0 contrast-100 brightness-100 scale-100"
                      ]}
                    />
                  <% end %>

                  <%!-- Processing Overlay --%>
                  <%= if @status == :processing do %>
                    <div class="absolute inset-0 bg-[#111111]/10 flex items-center justify-center backdrop-blur-[2px]">
                      <div class="bg-[#fcfbf9] border border-[#111111] px-6 py-3 shadow-xl">
                        <span class="font-sans uppercase tracking-widest text-xs font-bold flex items-center gap-3">
                          <span class="w-2 h-2 bg-[#111111] rounded-full animate-ping"></span>
                          Analyzing Subject...
                        </span>
                      </div>
                    </div>
                  <% end %>

                  <%!-- Failed Overlay --%>
                  <%= if @status == :failed do %>
                    <div class="absolute inset-0 bg-red-900/20 flex items-center justify-center backdrop-blur-[2px]">
                      <div class="bg-[#fcfbf9] border border-red-800 px-6 py-3 shadow-xl">
                        <span class="font-sans uppercase tracking-widest text-xs font-bold text-red-800 flex items-center gap-3">
                          <span class="w-2 h-2 bg-red-800 rounded-full"></span>
                          Curation Failed
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <%!-- Submit Button (Only shows when image is queued but not submitted) --%>
            <%= if @uploads.photo.entries != [] and @status == :idle do %>
              <div class="mt-6 flex justify-end">
                <button type="submit" class="font-sans uppercase tracking-widest text-sm bg-[#111111] text-[#fcfbf9] px-8 py-4 hover:bg-gray-800 transition-colors">
                  Commence Curation →
                </button>
              </div>
            <% end %>
          </form>
        </div>

        <%!-- Right Column: The Museum Placard / Editorial Details --%>
        <div class="lg:col-span-5 flex flex-col pt-8 lg:pt-0">

          <div class="sticky top-12">
            <h2 class="font-sans uppercase tracking-[0.2em] text-xs font-bold border-b border-[#111111] pb-2 mb-8">
              Archival Metadata
            </h2>

            <%= if @metadata do %>
              <%!-- The Placard Reveal --%>
              <div class="animate-in fade-in slide-in-from-bottom-4 duration-1000">
                <h3 class="text-4xl font-serif leading-tight mb-2"><%= @metadata["subject"] %></h3>
                <p class="font-sans uppercase tracking-widest text-xs text-gray-500 mb-8">
                  Format: <%= if @metadata["is_macro"], do: "Macro Study", else: "Standard Exposure" %>
                </p>

                <div class="space-y-6 text-lg leading-relaxed border-l-2 border-gray-200 pl-6 mb-10">
                  <p><strong class="font-sans uppercase tracking-widest text-xs block text-gray-400 mb-1">Atmosphere</strong> <%= @metadata["artistic_mood"] %></p>
                  <p><strong class="font-sans uppercase tracking-widest text-xs block text-gray-400 mb-1">Lighting Critique</strong> <%= @metadata["lighting_critique"] %></p>
                </div>

                <div class="border-t border-gray-200 pt-6">
                  <strong class="font-sans uppercase tracking-widest text-xs block text-gray-400 mb-4">Indexing Tags</strong>
                  <div class="flex flex-wrap gap-2">
                    <%= for tag <- @metadata["suggested_tags"] do %>
                      <span class="font-sans text-xs uppercase tracking-wider border border-[#111111] px-3 py-1 hover:bg-[#111111] hover:text-[#fcfbf9] transition-colors cursor-default">
                        <%= String.downcase(tag) %>
                      </span>
                    <% end %>
                  </div>
                </div>

                <button phx-click="reset" class="mt-12 font-sans uppercase tracking-widest text-xs border-b border-[#111111] pb-1 hover:text-gray-500 hover:border-gray-500 transition-colors">
                  + Curate Another Piece
                </button>
              </div>
            <% else %>
              <%!-- Empty State --%>
              <div class="font-serif italic text-lg">
                <%= cond do %>
                  <% @status == :processing -> %>
                    <p class="text-gray-400">The system is currently observing the artwork. Awaiting transmission...</p>
                  <% @status == :failed -> %>
                    <p class="text-red-800">The curation service could not be reached. Please verify the AI worker is running and try again.</p>
                    <button phx-click="reset" class="mt-6 font-sans not-italic uppercase tracking-widest text-xs border-b border-red-800 pb-1 text-red-800 hover:text-red-600 hover:border-red-600 transition-colors">
                      ↩ Try Again
                    </button>
                  <% true -> %>
                    <p class="text-gray-400">No piece is currently under observation. Please submit a photograph to the canvas.</p>
                <% end %>
              </div>
            <% end %>
          </div>

        </div>
      </div>
    </div>
    """
  end
end
