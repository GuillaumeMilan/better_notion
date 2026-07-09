defmodule BetterNotion.ApiPlug do
  @moduledoc """
  REST API for CLI access to BetterNotion tools.

  Provides simple POST endpoints that map directly to MCP.Controller functions,
  bypassing the MCP protocol overhead.
  """

  use Plug.Router

  alias BetterNotion.MCP.Controller
  alias BetterNotion.NotionAuth

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  post "/api/ping" do
    handle_tool(conn, &Controller.ping/2, conn.body_params)
  end

  post "/api/login" do
    case NotionAuth.start_auth_flow(conn.body_params["base_url"]) do
      {:ok, auth_url} ->
        send_json(conn, 200, %{ok: true, text: auth_url})

      {:error, reason} ->
        send_json(conn, 200, %{ok: false, error: "Failed to start login: #{inspect(reason)}"})
    end
  end

  post "/api/fetch_document" do
    with_auth(conn, fn -> handle_tool(conn, &Controller.fetch_document/2, conn.body_params) end)
  end

  post "/api/commit_document" do
    with_auth(conn, fn -> handle_tool(conn, &Controller.commit_document/2, conn.body_params) end)
  end

  post "/api/fetch_view_entries" do
    with_auth(conn, fn -> handle_tool(conn, &Controller.fetch_view_entries/2, conn.body_params) end)
  end

  post "/api/fetch_properties" do
    with_auth(conn, fn -> handle_tool(conn, &Controller.fetch_properties/2, conn.body_params) end)
  end

  post "/api/update_properties" do
    with_auth(conn, fn -> handle_tool(conn, &Controller.update_properties/2, conn.body_params) end)
  end

  post "/api/create_page_on_view" do
    with_auth(conn, fn -> handle_tool(conn, &Controller.create_page_on_view/2, conn.body_params) end)
  end

  match _ do
    send_json(conn, 404, %{ok: false, error: "Not found"})
  end

  # Gate a tool call behind authentication. Returns a structured
  # `not_authenticated` error (rather than blocking) when the user is logged
  # out, so the CLI can prompt them to run `better-notion login`.
  defp with_auth(conn, fun) do
    case NotionAuth.ensure_authenticated() do
      {:ok, _token} ->
        fun.()

      {:error, _reason} ->
        send_json(conn, 200, %{
          ok: false,
          error: "Not authenticated. Run `better-notion login` to connect to Notion.",
          error_code: "not_authenticated"
        })
    end
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
