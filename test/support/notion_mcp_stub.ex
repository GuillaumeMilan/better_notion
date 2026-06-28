defmodule BetterNotion.NotionMcpStub do
  @moduledoc """
  In-memory fake of the Notion MCP server for tests.

  `BetterNotion.Document` talks to the Notion MCP through a module resolved at
  runtime (see `BetterNotion.Document.notion_mcp/0`). In tests we point that at
  this stub via:

      Application.put_env(:better_notion, :notion_mcp, BetterNotion.NotionMcpStub)

  The stub holds page contents in an Agent and faithfully reproduces the
  observed behavior of the real `notion-update-page` tool (validated against the
  live MCP in `scripts/empty_page_repro.exs`):

  - `update_content` with a `content_update` whose `old_str` does not match the
    current page content is a **silent no-op** that still returns `{:ok, _}`.
    In particular, on an empty page an empty `old_str` matches nothing, so the
    content is never written — this is the bug being fixed.
  - `insert_content` appends the given markdown to the page.

  It also records the sequence of calls so tests can assert which tool/command
  was used.
  """
  use Agent

  @agent __MODULE__

  @doc "Start the stub. `pages` is a map of `page_id => content`."
  def start_link(pages \\ %{}) do
    Agent.start_link(fn -> %{pages: pages, calls: []} end, name: @agent)
  end

  @doc "Current stored content for a page."
  def page_content(page_id), do: Agent.get(@agent, &Map.get(&1.pages, page_id, ""))

  @doc "Recorded calls, in the order they were made."
  def calls, do: Agent.get(@agent, &Enum.reverse(&1.calls))

  # --- MCP API consumed by BetterNotion.Document ---

  def fetch_document(page_id) do
    record({:fetch_document, page_id})
    {:ok, page_content(page_id)}
  end

  def update_page(page_id, updates) do
    record({:update_page, page_id, updates})

    new_content =
      Enum.reduce(updates, page_content(page_id), fn %{old_str: old, new_str: new}, content ->
        # Mirror Notion: a non-matching old_str (e.g. "" on an empty page) is a
        # silent no-op rather than an error.
        if old != "" and String.contains?(content, old) do
          String.replace(content, old, new)
        else
          content
        end
      end)

    put_content(page_id, new_content)
    {:ok, %{"content" => [%{"type" => "text", "text" => "{\"page_id\":\"#{page_id}\"}"}]}}
  end

  def append_to_page(page_id, content) do
    record({:append_to_page, page_id, content})

    existing = page_content(page_id)
    new_content = if existing == "", do: content, else: existing <> "\n" <> content

    put_content(page_id, new_content)
    {:ok, %{"content" => [%{"type" => "text", "text" => "{\"page_id\":\"#{page_id}\"}"}]}}
  end

  defp put_content(page_id, content) do
    Agent.update(@agent, &put_in(&1, [:pages, page_id], content))
  end

  defp record(call) do
    Agent.update(@agent, &Map.update!(&1, :calls, fn calls -> [call | calls] end))
  end
end
