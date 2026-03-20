defmodule Orchestrator.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OrchestratorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
