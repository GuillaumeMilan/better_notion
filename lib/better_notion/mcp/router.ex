defmodule BetterNotion.MCP.Router do
  @moduledoc """
  MCP Router defining available tools.
  """

  use McpServer.Router

  tool "ping", "A simple ping tool that returns pong", BetterNotion.MCP.Controller, :ping do
    output_field("response", "The pong response", :string)
  end

  tool "fetch_document",
       "Fetches a Notion document and returns its content as line-numbered markdown. " <>
         "Accepts a Notion URL or page ID. Use offset/limit to read large documents in chunks.",
       BetterNotion.MCP.Controller,
       :fetch_document,
       read_only_hint: true,
       idempotent_hint: true do
    input_field("page", "Notion page URL or page UUID", :string, required: true)
    input_field("offset", "Line number to start reading from (1-based, default: 1)", :integer)
    input_field("limit", "Maximum number of lines to return", :integer)
  end
end
