defmodule BetterNotion.MCP.Router do
  @moduledoc """
  MCP Router defining available tools.
  """

  use McpServer.Router

  tool "ping", "A simple ping tool that returns pong", BetterNotion.MCP.Controller, :ping do
    output_field("response", "The pong response", :string)
  end

  tool "fetch_document",
       """
       Fetches a Notion document and returns a path where the document has been saved.
       Accepts a Notion URL or page ID.
       Optionally the tool accept to receive a path to a local file where the document should be saved. If not provided, the tool will create a temporary file and return its path.
       """,
       BetterNotion.MCP.Controller,
       :fetch_document,
       read_only_hint: true,
       idempotent_hint: true do
    input_field("page", "Notion page URL or page UUID", :string, required: true)

    input_field(
      "path",
      """
      Optional path to save the document. If not provided, a temporary file will be created.
      PREFER providing a path when you need to edit the document, as it will avoid the user to have to validate the file access in the OS.
      The path MUST be an absolute path.
      """,
      :string
    )
  end
end
