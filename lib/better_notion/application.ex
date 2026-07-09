defmodule BetterNotion.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:better_notion, :mcp_port, 4000)
    ip = bind_ip()

    Logger.info("[BetterNotion] Starting server on IP: #{inspect ip} and PORT: #{inspect port}")

    children = [
      BetterNotion.TokenStore,
      {Bandit,
       plug:
         {BetterNotion.RootPlug,
          router: BetterNotion.MCP.Router,
          server_info: %{name: "BetterNotion MCP Server", version: "0.1.0"}},
       port: port,
       ip: ip},
      BetterNotion.NotionMcpManager
    ]

    opts = [strategy: :one_for_one, name: BetterNotion.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp bind_ip do
    :better_notion
    |> Application.get_env(:bind_ip, "127.0.0.1")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> address
      {:error, _} -> {127, 0, 0, 1}
    end
  end
end
