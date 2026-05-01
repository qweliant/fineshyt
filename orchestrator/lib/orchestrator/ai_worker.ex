defmodule Orchestrator.AiWorker do
  @moduledoc """
  Resolves URLs for the Python AI worker service.

  The base URL is configurable so the same code works for both:

    * native dev: AI worker runs on `http://127.0.0.1:8000` on the host
    * docker compose: orchestrator and ai_worker live in separate
      containers, reachable as `http://ai_worker:8000` over the
      compose network

  Set the `AI_WORKER_URL` env var to override; otherwise we default to
  the native-dev URL. The compose file passes the docker-side URL in.
  """

  @default_base_url "http://127.0.0.1:8000"

  @doc """
  Returns the absolute URL for an AI worker endpoint.

  ## Examples

      iex> Orchestrator.AiWorker.url("/api/v1/curate")
      "http://127.0.0.1:8000/api/v1/curate"
  """
  def url(path) when is_binary(path) do
    base = Application.get_env(:orchestrator, :ai_worker_url, @default_base_url)
    base <> path
  end
end
