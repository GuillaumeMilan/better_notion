defmodule BetterNotion.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:better_notion, :mcp_port, 4000)

    children = [
      {Bandit,
       plug:
         {McpServer.HttpPlug,
          router: BetterNotion.MCP.Router,
          server_info: %{name: "BetterNotion MCP Server", version: "0.1.0"}},
       port: port,
       ip: {127, 0, 0, 1}}
    ]

    opts = [strategy: :one_for_one, name: BetterNotion.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
