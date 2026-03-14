defmodule BetterNotion.MCP.Controller do
  @moduledoc """
  Controller module for MCP tools.
  """

  alias McpServer.Tool.Content, as: ToolContent
  alias McpServer.Tool.CallResult

  @fixtures_dir Application.app_dir(:better_notion, "priv/fixtures")

  def ping(_conn, _args) do
    {:ok, CallResult.new(content: [ToolContent.text("pong")])}
  end

  def fetch_document(_conn, %{"page" => page} = args) do
    page_id = extract_page_id(page)
    path = args["path"] || Path.join(System.tmp_dir!(), "#{page_id}.md")

    unless Path.absname(path) == path do
      raise ArgumentError, "path must be absolute, got: #{path}"
    end

    case fetch_document_from_notion(page_id) do
      {:ok, content} ->
        File.write!(path, content)
        {:ok, CallResult.new(content: [ToolContent.text(path)])}

      {:error, :enoent} ->
        {:error, "Document not found: #{page_id}"}
    end
  end

  defp extract_page_id(page) do
    case URI.parse(page) do
      %URI{host: host, path: path} when not is_nil(host) and not is_nil(path) ->
        path
        |> String.split("/")
        |> List.last("")
        |> String.split("-")
        |> List.last("")

      _ ->
        page
    end
  end

  defp fetch_document_from_notion(page_id) do
    # For demonstration, we read from a local fixture file named after the page_id.
    # In a real implementation, this would call the Notion API to fetch the page content.
    file_path = Path.join(@fixtures_dir, "#{page_id}.md")

    case File.read(file_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end
end
