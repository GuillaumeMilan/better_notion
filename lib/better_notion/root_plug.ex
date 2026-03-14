defmodule BetterNotion.RootPlug do
  @moduledoc """
  Top-level Plug that dispatches requests between the OAuth callback endpoint
  and the MCP server.

  - `/oauth/*` routes go to `BetterNotion.OAuthCallbackPlug`
  - All other routes go to `McpServer.HttpPlug`
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    mcp_opts = McpServer.HttpPlug.init(opts)
    oauth_opts = BetterNotion.OAuthCallbackPlug.init([])
    %{mcp_opts: mcp_opts, oauth_opts: oauth_opts}
  end

  @impl true
  def call(%Plug.Conn{request_path: "/oauth" <> _} = conn, %{oauth_opts: oauth_opts}) do
    BetterNotion.OAuthCallbackPlug.call(conn, oauth_opts)
  end

  def call(conn, %{mcp_opts: mcp_opts}) do
    McpServer.HttpPlug.call(conn, mcp_opts)
  end
end
