defmodule BetterNotion.PageDuplication do
  @moduledoc """
  Pure helpers backing `BetterNotion.NotionMcpManager.duplicate_page/1`.

  These functions hold the parsing and decision logic involved in duplicating
  a Notion page, kept free of any network access so they can be unit tested:

    * extracting the new page id/url from the `notion-duplicate-page` response,
    * reading a page's title out of its fetched `<properties>` block, and
    * recognising the transient error Notion returns while a duplication is
      still being finalized (so the title rename can be retried).
  """

  alias BetterNotion.Document

  @doc """
  Extracts the new page id and url from a `notion-duplicate-page` tool result.

  The duplicate tool returns free-form text referencing the new page's URL, so
  we pull the first URL out and derive the page id from it.
  """
  @spec parse_duplicate_result(map()) ::
          {:ok, %{page_id: String.t(), url: String.t()}}
          | {:error, {:unexpected_duplicate_response, String.t()}}
  def parse_duplicate_result(result) do
    text = get_in(result, ["content", Access.at(0), "text"]) || ""

    url =
      case Regex.run(~r/https?:\/\/[^\s"'<>)\]]+/i, text) do
        [found | _] -> found
        _ -> nil
      end

    id = if is_binary(url), do: Document.extract_page_id(url), else: nil

    if is_binary(id) and id != "" do
      {:ok, %{page_id: id, url: url || "https://www.notion.so/#{id}"}}
    else
      {:error, {:unexpected_duplicate_response, text}}
    end
  end

  @doc """
  Returns the value of `title_property` from a fetched page's `<properties>`
  block (the text of a `notion-fetch` result), as a string.
  """
  @spec read_title(String.t(), String.t()) :: {:ok, String.t()} | {:error, any()}
  def read_title(page_text, title_property) do
    case Jason.decode(properties_json(page_text)) do
      {:ok, properties} -> {:ok, to_string(Map.get(properties, title_property, ""))}
      {:error, _} = error -> error
    end
  end

  @doc """
  Returns the JSON string held inside the `<properties>...</properties>`
  block(s) of a fetched page's text.
  """
  @spec properties_json(String.t()) :: String.t()
  def properties_json(page_text) do
    Regex.scan(~r/<properties>(.*?)<\/properties>/s, page_text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc """
  Returns the data source id of a page's parent database, parsed from the
  `<parent-data-source url="collection://..."/>` tag of a fetched page's text,
  or `nil` for a standalone (non-database) page.
  """
  @spec parent_data_source_id(String.t()) :: String.t() | nil
  def parent_data_source_id(page_text) do
    case Regex.run(~r/<parent-data-source url="(?:\{\{)?collection:\/\/([^"\}]+)/, page_text,
           capture: :all_but_first
         ) do
      [data_source_id] -> data_source_id
      _ -> nil
    end
  end

  @doc """
  True while Notion is still finalizing a duplicated page, i.e. the page is not
  yet updatable. Used to decide whether the title rename should be retried.
  """
  @spec duplicate_in_progress?(any()) :: boolean()
  def duplicate_in_progress?(reason) do
    text = if is_binary(reason), do: reason, else: inspect(reason)

    String.contains?(text, "is not a page or database") or
      String.contains?(text, "Could not find") or
      String.contains?(text, "validation_error")
  end
end
