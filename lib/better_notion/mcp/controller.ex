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
    fixture_path = Path.join(@fixtures_dir, "#{page_id}.md")

    case File.read(fixture_path) do
      {:ok, content} ->
        output = format_file_content(content, args)
        {:ok, CallResult.new(content: [ToolContent.text(output)])}

      {:error, :enoent} ->
        {:error, "Document not found: #{page_id}"}
    end
  end

  def format_file_content(content, args \\ %{}) do
    lines = String.split(content, "\n")
    total_lines = length(lines)
    biggest_line_num = total_lines |> Integer.to_string() |> String.length()

    offset = max((args["offset"] || 1) - 1, 0)
    limit = args["limit"]

    selected =
      lines
      |> Enum.with_index(1)
      |> Enum.drop(offset)
      |> then(fn lines ->
        if limit, do: Enum.take(lines, limit), else: lines
      end)

    numbered =
      selected
      |> Enum.map(fn {line, num} ->
        String.pad_leading("  " <> Integer.to_string(num), biggest_line_num) <> "  " <> line
      end)
      |> Enum.join("\n")

    remaining = total_lines - offset - length(selected)

    if limit && remaining > 0 do
      numbered <> "\n... (#{remaining} more lines)"
    else
      numbered
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
end
