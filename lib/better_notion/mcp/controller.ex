defmodule BetterNotion.MCP.Controller do
  @moduledoc """
  Controller module for MCP tools.
  """

  alias McpServer.Tool.Content, as: ToolContent
  alias McpServer.Tool.CallResult
  alias BetterNotion.Document

  def ping(_conn, _args) do
    {:ok, CallResult.new(content: [ToolContent.text("pong")])}
  end

  def fetch_document(_conn, %{"page" => page} = args) do
    page_id = Document.extract_page_id(page)

    path =
      Map.get(args, "path") ||
        System.tmp_dir!()
        |> Path.join("notion_#{page_id}.md")

    case Document.fetch(page_id, path) do
      {:ok, _content} ->
        {:ok, CallResult.new(content: [ToolContent.text(path)])}

      {:error, :enoent} ->
        {:error, "Document not found: #{page_id}"}
    end
  end
end
