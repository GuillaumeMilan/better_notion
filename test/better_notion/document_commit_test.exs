defmodule BetterNotion.DocumentCommitTest do
  # async: false — the Notion MCP backend is injected via Application env, which
  # is global, and the stub is a single named Agent.
  use ExUnit.Case, async: false

  alias BetterNotion.Document
  alias BetterNotion.NotionMcpStub

  @page_id "test-page-id"

  setup context do
    {:ok, _stub} = start_supervised({NotionMcpStub, context[:pages] || %{}})
    Application.put_env(:better_notion, :notion_mcp, NotionMcpStub)

    doc_path =
      Path.join(System.tmp_dir!(), "bn_commit_test_#{System.unique_integer([:positive])}.md")

    on_exit(fn ->
      Application.delete_env(:better_notion, :notion_mcp)
      File.rm(doc_path)
    end)

    %{doc_path: doc_path}
  end

  describe "commit/1 when the Notion page is empty" do
    @tag pages: %{@page_id => ""}
    test "pushes the local content to Notion", %{doc_path: doc_path} do
      # Fetch the (empty) page, then edit the local file as a user would.
      {:ok, ""} = Document.fetch(@page_id, doc_path)
      File.write!(doc_path, "# My doc\n\nHello world")

      assert {:ok, :committed} = Document.commit(doc_path)

      # The whole point: the edited content must actually reach Notion. With the
      # old update_content/empty-old_str path this silently stayed "" (the bug).
      assert NotionMcpStub.page_content(@page_id) == "# My doc\n\nHello world"
    end

    @tag pages: %{@page_id => ""}
    test "appends instead of doing an empty-string replace", %{doc_path: doc_path} do
      {:ok, ""} = Document.fetch(@page_id, doc_path)
      File.write!(doc_path, "# My doc\n\nHello world")

      assert {:ok, :committed} = Document.commit(doc_path)

      commands = NotionMcpStub.calls() |> Enum.map(&elem(&1, 0))
      assert :append_to_page in commands
      refute :update_page in commands
    end
  end

  describe "commit/1 when the Notion page already has content" do
    @tag pages: %{@page_id => "# My doc\n\nHello world"}
    test "uses update_content to apply the diff", %{doc_path: doc_path} do
      {:ok, "# My doc\n\nHello world"} = Document.fetch(@page_id, doc_path)
      File.write!(doc_path, "# My doc\n\nHello there")

      assert {:ok, :committed} = Document.commit(doc_path)

      assert NotionMcpStub.page_content(@page_id) == "# My doc\n\nHello there"

      commands = NotionMcpStub.calls() |> Enum.map(&elem(&1, 0))
      assert :update_page in commands
      refute :append_to_page in commands
    end
  end
end
