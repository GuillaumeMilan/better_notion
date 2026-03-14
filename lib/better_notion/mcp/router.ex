defmodule BetterNotion.MCP.Router do
  @moduledoc """
  MCP Router defining available tools.
  """

  use McpServer.Router

  tool "ping", "A simple ping tool that returns pong", BetterNotion.MCP.Controller, :ping do
    output_field("response", "The pong response", :string)
  end
end
