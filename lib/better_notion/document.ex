defmodule BetterNotion.Document do
  @moduledoc """
  Handles fetching Notion documents and managing their metadata.
  """

  @fixtures_dir Application.app_dir(:better_notion, "priv/fixtures")

  def fetch(page_id, path) do
    case fetch_from_notion(page_id) do
      {:ok, content} ->
        File.write!(path, content)
        create_metadata!(page_id, path, content)
        {:ok, content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def extract_page_id(page) do
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

  @doc """
  Diffs the current content of the local document with the original content fetched from Notion,
  using the metadata to identify the original page and content.

  It returns either:
  - `{:ok, :no_conflict, new_content}` if there are no conflicts and the document can be safely updated.
  - `{:ok, :conflict, diff}` if there are conflicts that need to be resolved before committing changes.
  - `{:error, reason}` if there was an error during the diffing process (e.g., missing metadata, file reading issues).
  """
  @spec diff(Path.t()) ::
          {:ok, :no_conflict, new_content :: String.t()}
          | {:ok, :conflict, diff :: String.t()}
          | {:error, any()}
  def diff(path) do
    meta_path = file_metadata_path(path)

    with {:ok, meta_content} <- File.read(meta_path),
         {:ok, metadata} <- Jason.decode(meta_content),
         {:ok, current_content} <- File.read(path),
         {:ok, server_content} <- fetch_from_notion(metadata["page_id"]) do
      diff3(current_content, metadata["content"], server_content)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp diff3(local, base, server) do
    tmp_dir = System.tmp_dir!()
    local_path = Path.join(tmp_dir, "diff3_local_#{System.unique_integer([:positive])}")
    base_path = Path.join(tmp_dir, "diff3_base_#{System.unique_integer([:positive])}")
    server_path = Path.join(tmp_dir, "diff3_server_#{System.unique_integer([:positive])}")

    try do
      File.write!(local_path, local)
      File.write!(base_path, base)
      File.write!(server_path, server)

      case System.cmd("diff3", ["-m", local_path, base_path, server_path]) do
        {output, 0} -> {:ok, :no_conflict, output}
        {output, 1} -> {:ok, :conflict, output}
        {_, 2} -> {:error, :diff3_error}
      end
    after
      File.rm(local_path)
      File.rm(base_path)
      File.rm(server_path)
    end
  end

  defp fetch_from_notion(page_id) do
    # For demonstration, we read from a local fixture file named after the page_id.
    # In a real implementation, this would call the Notion API to fetch the page content.
    File.read(Path.join(@fixtures_dir, page_id))
  end

  defp create_metadata!(page_id, path, content) do
    metadata = %{
      page_id: page_id,
      path: path,
      created_at: DateTime.utc_now(),
      content: content
    }

    meta_path = file_metadata_path(path)
    File.mkdir_p!(Path.dirname(meta_path))
    File.write!(meta_path, Jason.encode!(metadata))
  end

  defp file_metadata_path(path) do
    # Git like path from hash of path, e.g. 322a8f8de3be81f1b48dcbe820cfef17 -> 32/2a8f8de3be81f1b48dcbe820cfef17
    hash = hash(path)
    subfolder = String.slice(hash, 0..1)
    filename = String.slice(hash, 2..-1//1)

    Path.join([:code.priv_dir(:better_notion), subfolder, filename])
  end

  defp hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
