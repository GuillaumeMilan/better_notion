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

    path =
      Map.get(args, "path") ||
        System.tmp_dir!()
        |> Path.join("notion_#{page_id}.md")

    case fetch_document_from_notion(page_id, path) do
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

  defp fetch_document_from_notion(page_id, path) do
    # For demonstration, we read from a local fixture file named after the page_id.
    # In a real implementation, this would call the Notion API to fetch the page content.
    case File.read(Path.join(@fixtures_dir, page_id)) do
      {:ok, content} ->
        create_meta_data(page_id, path, content)
        {:ok, content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp metafolder() do
    :code.priv_dir(:better_notion)
  end

  def create_meta_data(page_id, path, content) do
    # Git like path from page_id, e.g. 322a8f8de3be81f1b48dcbe820cfef17 -> 32/2a8f8de3be81f1b48dcbe820cfef17
    subfolder = String.slice(page_id, 0..1)
    filename = String.slice(page_id, 2..-1//1)

    metadata = %{
      page_id: page_id,
      path: path,
      created_at: DateTime.utc_now(),
      content: content
    }

    Path.join([metafolder(), subfolder])
    |> tap(&File.mkdir_p!/1)
    |> Path.join(filename)
    |> File.write(Jason.encode!(metadata))
  end
end
