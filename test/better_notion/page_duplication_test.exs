defmodule BetterNotion.PageDuplicationTest do
  use ExUnit.Case, async: true

  alias BetterNotion.PageDuplication

  # Builds a fetched-page text block in the shape `notion-fetch` returns.
  defp page_text(properties, opts \\ []) do
    data_source =
      Keyword.get(opts, :data_source, "collection://841c7a8d-a929-4c21-9e54-0c10b130a14a")

    parent =
      if data_source,
        do: ~s(<parent-data-source url="#{data_source}" name="TECH TICKETS"/>),
        else: ""

    """
    <page url="https://app.notion.com/p/abc">
    <ancestor-path>
    #{parent}
    </ancestor-path>
    <properties>
    #{Jason.encode!(properties)}
    </properties>
    <content>
    body
    </content>
    </page>
    """
  end

  defp duplicate_result(text), do: %{"content" => [%{"text" => text}]}

  describe "parse_duplicate_result/1" do
    test "extracts id and url from an app.notion.com URL" do
      result =
        duplicate_result(
          "The page is being duplicated: https://app.notion.com/p/38da8f8de3be81e1bc32d5886904098e"
        )

      assert {:ok, %{page_id: id, url: url}} = PageDuplication.parse_duplicate_result(result)
      assert id == "38da8f8de3be81e1bc32d5886904098e"
      assert url == "https://app.notion.com/p/38da8f8de3be81e1bc32d5886904098e"
    end

    test "extracts the id from a slugged notion.so URL" do
      result =
        duplicate_result(
          "Created https://www.notion.so/My-Page-38da8f8de3be81e1bc32d5886904098e and done."
        )

      assert {:ok, %{page_id: "38da8f8de3be81e1bc32d5886904098e"}} =
               PageDuplication.parse_duplicate_result(result)
    end

    test "stops the URL at trailing punctuation/quotes" do
      result =
        duplicate_result(~s(see "https://app.notion.com/p/38da8f8de3be81e1bc32d5886904098e"))

      assert {:ok, %{url: url}} = PageDuplication.parse_duplicate_result(result)
      assert url == "https://app.notion.com/p/38da8f8de3be81e1bc32d5886904098e"
    end

    test "errors when no URL is present" do
      assert {:error, {:unexpected_duplicate_response, "no link here"}} =
               PageDuplication.parse_duplicate_result(duplicate_result("no link here"))
    end

    test "errors on an empty/malformed result" do
      assert {:error, {:unexpected_duplicate_response, ""}} =
               PageDuplication.parse_duplicate_result(%{})
    end
  end

  describe "read_title/2" do
    test "reads a title property value" do
      text = page_text(%{"Ticket name" => "Hello world", "Status*" => "BACKLOG"})
      assert PageDuplication.read_title(text, "Ticket name") == {:ok, "Hello world"}
    end

    test "round-trips escaped markdown in the title" do
      text = page_text(%{"Ticket name" => "\\[micro\\] Old measurement UI"})

      assert PageDuplication.read_title(text, "Ticket name") ==
               {:ok, "\\[micro\\] Old measurement UI"}
    end

    test "returns an empty string for a missing property" do
      text = page_text(%{"Ticket name" => "Hello"})
      assert PageDuplication.read_title(text, "Nonexistent") == {:ok, ""}
    end

    test "errors when the properties block is not valid JSON" do
      assert {:error, _} =
               PageDuplication.read_title("<properties>not json</properties>", "title")
    end
  end

  describe "properties_json/1" do
    test "extracts the JSON inside the properties block" do
      text = page_text(%{"a" => 1})
      assert PageDuplication.properties_json(text) |> Jason.decode!() == %{"a" => 1}
    end

    test "returns an empty string when there is no properties block" do
      assert PageDuplication.properties_json("<page></page>") == ""
    end
  end

  describe "parent_data_source_id/1" do
    test "extracts the collection id from a database page" do
      text = page_text(%{"Ticket name" => "x"})
      assert PageDuplication.parent_data_source_id(text) == "841c7a8d-a929-4c21-9e54-0c10b130a14a"
    end

    test "handles a {{collection://...}} wrapped url" do
      text =
        page_text(%{"Ticket name" => "x"},
          data_source: "{{collection://841c7a8d-a929-4c21-9e54-0c10b130a14a}}"
        )

      assert PageDuplication.parent_data_source_id(text) == "841c7a8d-a929-4c21-9e54-0c10b130a14a"
    end

    test "returns nil for a standalone page" do
      text = page_text(%{"title" => "x"}, data_source: nil)
      assert PageDuplication.parent_data_source_id(text) == nil
    end
  end

  describe "duplicate_in_progress?/1" do
    test "true for the 'not a page or database' error" do
      assert PageDuplication.duplicate_in_progress?(
               "Object 38da... is not a page or database and cannot be updated"
             )
    end

    test "true for a validation_error payload" do
      assert PageDuplication.duplicate_in_progress?(~s({"code":"validation_error"}))
    end

    test "true for a 'Could not find' error" do
      assert PageDuplication.duplicate_in_progress?("Could not find page with id ...")
    end

    test "handles a non-binary reason via inspect" do
      assert PageDuplication.duplicate_in_progress?({:error, "is not a page or database"})
      refute PageDuplication.duplicate_in_progress?({:error, :timeout})
    end

    test "false for an unrelated error" do
      refute PageDuplication.duplicate_in_progress?("permission denied")
    end
  end
end
