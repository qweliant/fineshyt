defmodule OrchestratorWeb.PageControllerTest do
  use OrchestratorWeb.ConnCase

  # `/` is CuratorLive (single-photo curation), not the Phoenix welcome page
  # the generator wrote this test against.
  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "FINESHYT."
  end
end
