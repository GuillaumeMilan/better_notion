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

  def commit_document(_conn, %{"path" => path}) do
    case Document.commit(path) do
      {:ok, :committed} ->
        {:ok, CallResult.new(content: [ToolContent.text("Document committed successfully")])}

      {:ok, {:conflict, diff}} ->
        {:error, "Conflict detected. Please resolve before committing:\n#{diff}"}

      {:error, reason} ->
        {:error, "Failed to commit document: #{inspect(reason)}"}
    end
  end

  def fetch_view_entries(_conn, %{"view_url" => view_url} = args) do
    additional_fields = Map.get(args, "additional_fields", [])

    case BetterNotion.NotionMcpManager.fetch_view_entries(view_url, additional_fields) do
      {:ok, %{has_more: has_more, results: results, other_fields: other_fields}} ->
        response =
          Jason.encode!(%{has_more: has_more, results: results, other_fields: other_fields})

        {:ok, CallResult.new(content: [ToolContent.text(response)])}

      {:error, reason} ->
        {:error, "Failed to fetch view entries: #{inspect(reason)}"}
    end
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
