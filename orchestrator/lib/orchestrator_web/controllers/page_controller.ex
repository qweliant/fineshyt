defmodule OrchestratorWeb.PageController do
  use OrchestratorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
