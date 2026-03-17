defmodule BetterNotion.MCP.Router do
  @moduledoc """
  MCP Router defining available tools.
  """

  use McpServer.Router

  tool "ping", "A simple ping tool that returns pong", BetterNotion.MCP.Controller, :ping do
    output_field("response", "The pong response", :string)
  end

  tool "commit_document",
       """
       Commits local changes to a Notion document back to Notion.
       Accepts the path to a local document that was previously fetched.
       Will detect conflicts between local and remote changes.
       """,
       BetterNotion.MCP.Controller,
       :commit_document do
    input_field("path", "Absolute path to the local document file", :string, required: true)
  end

  tool "fetch_view_entries",
       """
       Fetches entries from a Notion database view.
       Accepts a Notion view URL (containing a view ID query parameter).
       Returns the filtered results based on the view's display properties.
       """,
       BetterNotion.MCP.Controller,
       :fetch_view_entries,
       read_only_hint: true,
       idempotent_hint: true do
    input_field("view_url", "Notion database view URL", :string, required: true)
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
