defmodule Orchestrator.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Reconcile the release's priv/static/uploads path with the
    # configured STATIC_UPLOADS_DIR before the endpoint comes up. See
    # ensure_uploads_symlink/0 below for the why.
    ensure_uploads_symlink()

    # The SQLite file's parent dir (e.g. ~/Library/Application Support/Fine.Shyt)
    # may not exist yet on a fresh install. ecto_sqlite3 creates the db file
    # but not intermediate dirs, so make them before the Repo starts.
    ensure_db_dir()

    children = [
      OrchestratorWeb.Telemetry,
      Orchestrator.Repo,
      {DNSCluster, query: Application.get_env(:orchestrator, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Orchestrator.PubSub},
      # Start a worker by calling: Orchestrator.Worker.start_link(arg)
      # {Orchestrator.Worker, arg},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Orchestrator.Finch},

      # Add Oban here!
      {Oban, Application.fetch_env!(:orchestrator, Oban)},
      # Start to serve requests, typically the last entry
      OrchestratorWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Orchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # If STATIC_UPLOADS_DIR is set, point the release's priv/static/uploads
  # path at it via a symlink. Plug.Static serves /uploads/* through
  # `:code.priv_dir(:orchestrator)` which is a path inside the release —
  # in Tauri C2 mode that path starts empty (we prune uploads from the
  # release artifact), so without this hook the gallery 404s every
  # thumbnail. Idempotent: skips when already a correct symlink, drains
  # any stray files into the configured dir first.
  defp ensure_uploads_symlink do
    case Application.get_env(:orchestrator, :uploads_dir) do
      nil ->
        :ok

      "" ->
        :ok

      configured ->
        File.mkdir_p!(configured)

        priv_link = Path.join([:code.priv_dir(:orchestrator), "static", "uploads"])
        File.mkdir_p!(Path.dirname(priv_link))

        existing_target = File.read_link(priv_link)

        cond do
          # priv_link already resolves to the SAME physical directory as
          # `configured` (same device+inode). This happens when running from
          # the source tree — Mix symlinks _build/.../priv to the source priv,
          # so :code.priv_dir already points at the configured uploads dir.
          # Without this guard the `File.dir?` branch below would drain and
          # `rm_rf!` the directory onto itself, destroying the uploads. Bail.
          same_directory?(priv_link, configured) ->
            :ok

          # Already pointing where we want — nothing to do.
          match?({:ok, ^configured}, existing_target) ->
            :ok

          # Some other symlink — replace it.
          match?({:ok, _}, existing_target) ->
            File.rm!(priv_link)
            File.ln_s!(configured, priv_link)

          # Real directory left over from a previous boot or the release
          # bundle. Drain anything inside into the configured dir, then
          # replace it with a symlink.
          File.dir?(priv_link) ->
            for entry <- File.ls!(priv_link) do
              src = Path.join(priv_link, entry)
              dst = Path.join(configured, entry)

              unless File.exists?(dst) do
                File.rename(src, dst)
              end
            end

            File.rm_rf!(priv_link)
            File.ln_s!(configured, priv_link)

          # Nothing there — just symlink.
          true ->
            File.ln_s!(configured, priv_link)
        end

        :ok
    end
  end

  # True when both paths exist and refer to the same physical directory
  # (same device + inode), following symlinks. Used to avoid operating on a
  # uploads dir that's already the configured target.
  defp same_directory?(a, b) do
    case {File.stat(a), File.stat(b)} do
      {{:ok, sa}, {:ok, sb}} ->
        sa.inode == sb.inode and sa.major_device == sb.major_device

      _ ->
        false
    end
  end

  # Ensure the parent directory of the configured SQLite database exists.
  # ecto_sqlite3 creates the db file itself but not intermediate dirs, which
  # matters for the prod default under a per-user data dir.
  defp ensure_db_dir do
    case Application.get_env(:orchestrator, Orchestrator.Repo)[:database] do
      path when is_binary(path) and path != "" ->
        File.mkdir_p!(Path.dirname(Path.expand(path)))

      _ ->
        :ok
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OrchestratorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
