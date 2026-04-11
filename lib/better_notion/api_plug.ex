defmodule BetterNotion.ApiPlug do
  @moduledoc """
  REST API for CLI access to BetterNotion tools.

  Provides simple POST endpoints that map directly to MCP.Controller functions,
  bypassing the MCP protocol overhead.
  """

  use Plug.Router

  alias BetterNotion.MCP.Controller

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  post "/api/ping" do
    handle_tool(conn, &Controller.ping/2, conn.body_params)
  end

  post "/api/fetch_document" do
    handle_tool(conn, &Controller.fetch_document/2, conn.body_params)
  end

  post "/api/commit_document" do
    handle_tool(conn, &Controller.commit_document/2, conn.body_params)
  end

  post "/api/fetch_view_entries" do
    handle_tool(conn, &Controller.fetch_view_entries/2, conn.body_params)
  end

  post "/api/update_properties" do
    handle_tool(conn, &Controller.update_properties/2, conn.body_params)
  end

  match _ do
    send_json(conn, 404, %{ok: false, error: "Not found"})
  end

  defp handle_tool(conn, fun, params) do
    case fun.(nil, params) do
      {:ok, result} ->
        text = result.content |> List.first() |> Map.get(:text, "")
        send_json(conn, 200, %{ok: true, text: text})

      {:error, message} ->
        send_json(conn, 200, %{ok: false, error: message})
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
