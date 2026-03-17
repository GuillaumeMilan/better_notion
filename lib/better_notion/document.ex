defmodule BetterNotion.Document do
  @moduledoc """
  Handles fetching Notion documents and managing their metadata.
  """

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

  def commit(path) do
    case diff(path) do
      {:ok, :no_conflict, new_content} ->
        case send_file_to_notion(path, new_content) do
          :ok ->
            File.rm!(path)
            File.rm_rf!(file_metadata_path(path))
            {:ok, :committed}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, :conflict, diff} ->
        # There are conflicts that need to be resolved before committing changes
        {:ok, {:conflict, diff}}

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

  def extract_view_id(view_url) do
    case URI.parse(view_url) do
      %URI{query: query} when not is_nil(query) ->
        query
        |> URI.decode_query()
        |> Map.get("v")

      _ ->
        nil
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
      update_metadata!(path, server_content)
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
    BetterNotion.NotionMcpManager.fetch_document(page_id)
  end

  def send_file_to_notion(path, content) do
    with {:ok, meta_content} <- File.read(file_metadata_path(path)),
         {:ok, metadata} <- Jason.decode(meta_content),
         updates = compute_updates(metadata["content"], content),
         {:ok, _} <- BetterNotion.NotionMcpManager.update_page(metadata["page_id"], updates) do
      update_metadata!(path, content)
    end
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

  defp update_metadata!(path, new_content) do
    meta_path = file_metadata_path(path)

    meta_content = File.read!(meta_path)
    metadata = Jason.decode!(meta_content)
    new_metadata = Map.put(metadata, "content", new_content)
    File.write!(meta_path, Jason.encode!(new_metadata))
  end

  defp file_metadata_path(path) do
    # Git like path from hash of path, e.g. 322a8f8de3be81f1b48dcbe820cfef17 -> 32/2a8f8de3be81f1b48dcbe820cfef17
    hash = hash(path)
    subfolder = String.slice(hash, 0..1)
    filename = String.slice(hash, 2..-1//1)

    Path.join([:code.priv_dir(:better_notion), subfolder, filename])
  end

  @doc """
  Computes the update chunks needed to transform `server_content` into `updated_content`.

  Returns a list of `%{old_str: String.t(), new_str: String.t()}` maps suitable
  for passing to `NotionMcpManager.update_page/2`.
  """
  @spec compute_updates(String.t(), String.t()) :: [%{old_str: String.t(), new_str: String.t()}]
  def compute_updates(server_content, updated_content) do
    server_lines = String.split(server_content, "\n")
    updated_lines = String.split(updated_content, "\n")

    List.myers_difference(server_lines, updated_lines)
    |> collect_raw_changes()
    |> ensure_unique_context(server_content)
    |> Enum.map(fn {old_lines, new_lines} ->
      %{old_str: Enum.join(old_lines, "\n"), new_str: Enum.join(new_lines, "\n")}
    end)
  end

  # Collects raw changes as {prev_eq, change_old, change_new, next_eq} tuples.
  defp collect_raw_changes(diff_ops) do
    collect_raw_changes(diff_ops, _prev_eq = [], [])
  end

  defp collect_raw_changes([], _prev_eq, acc), do: Enum.reverse(acc)

  defp collect_raw_changes([{:eq, lines} | rest], _prev_eq, acc) do
    collect_raw_changes(rest, lines, acc)
  end

  defp collect_raw_changes([{op, lines} | rest], prev_eq, acc) when op in [:del, :ins] do
    {change_old, change_new, rest} = collect_change(op, lines, rest)
    {next_eq, rest} = take_next_eq(rest)

    entry = {prev_eq, change_old, change_new, next_eq}
    collect_raw_changes(rest, next_eq, [entry | acc])
  end

  # Collects consecutive :del/:ins operations into a single change.
  defp collect_change(:del, del_lines, [{:ins, ins_lines} | rest]) do
    {del_lines, ins_lines, rest}
  end

  defp collect_change(:del, del_lines, rest), do: {del_lines, [], rest}
  defp collect_change(:ins, ins_lines, rest), do: {[], ins_lines, rest}

  # Takes the next :eq segment from the remaining ops, if present.
  defp take_next_eq([{:eq, lines} | rest]), do: {lines, rest}
  defp take_next_eq(rest), do: {[], rest}

  # Adds minimal surrounding context to each change so that old_str is
  # unique within the server content. Starts with 1 line of context and
  # expands until unique or all available context is used.
  # When a chunk can't be made unique with its available context, it gets
  # merged with the next chunk (absorbing the shared eq segment).
  defp ensure_unique_context(raw_changes, server_content) do
    raw_changes
    |> merge_until_unique(server_content)
    |> Enum.map(fn {prev_eq, change_old, change_new, next_eq} ->
      expand_context(prev_eq, change_old, change_new, next_eq, server_content, _n = 1)
    end)
  end

  # Iteratively merges adjacent raw changes when a chunk cannot be made
  # unique with its available context alone.
  defp merge_until_unique(raw_changes, server_content) do
    case try_merge_pass(raw_changes, server_content) do
      {:unchanged, result} -> result
      {:merged, result} -> merge_until_unique(result, server_content)
    end
  end

  defp try_merge_pass([], _server_content), do: {:unchanged, []}
  defp try_merge_pass([single], _server_content), do: {:unchanged, [single]}

  defp try_merge_pass(
         [
           {prev_eq1, old1, new1, shared_eq} = chunk1,
           {_prev_eq2, old2, new2, next_eq2} = chunk2 | rest
         ],
         server_content
       ) do
    if needs_merge?(chunk1, server_content) or needs_merge?(chunk2, server_content) do
      merged = {prev_eq1, old1 ++ shared_eq ++ old2, new1 ++ shared_eq ++ new2, next_eq2}
      {:merged, [merged | rest]}
    else
      {status, tail} = try_merge_pass([chunk2 | rest], server_content)
      {status, [chunk1 | tail]}
    end
  end

  # Checks if a chunk cannot be made unique with all its available context.
  defp needs_merge?({prev_eq, change_old, _change_new, next_eq}, server_content) do
    old_lines = prev_eq ++ change_old ++ next_eq
    old_str = Enum.join(old_lines, "\n")
    not unique_in?(old_str, server_content)
  end

  defp expand_context(prev_eq, change_old, change_new, next_eq, server_content, n) do
    ctx_before = last_n(prev_eq, n)
    ctx_after = first_n(next_eq, n)

    old_lines = ctx_before ++ change_old ++ ctx_after
    old_str = Enum.join(old_lines, "\n")

    max_context_reached =
      length(ctx_before) >= length(prev_eq) and length(ctx_after) >= length(next_eq)

    if max_context_reached or unique_in?(old_str, server_content) do
      new_lines = ctx_before ++ change_new ++ ctx_after
      {old_lines, new_lines}
    else
      expand_context(prev_eq, change_old, change_new, next_eq, server_content, n + 1)
    end
  end

  defp unique_in?("", _content), do: false

  defp unique_in?(substring, content) do
    count_occurrences(content, substring, 0) == 1
  end

  defp count_occurrences(content, substring, count) when count <= 1 do
    case :binary.match(content, substring) do
      {pos, _len} ->
        rest_start = pos + 1
        rest = :binary.part(content, rest_start, byte_size(content) - rest_start)
        count_occurrences(rest, substring, count + 1)

      :nomatch ->
        count
    end
  end

  defp count_occurrences(_content, _substring, count), do: count

  defp last_n(list, n), do: Enum.slice(list, -n..-1//1)
  defp first_n(list, n), do: Enum.take(list, n)

  defp hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
