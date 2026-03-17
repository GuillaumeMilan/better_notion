defmodule BetterNotion.NotionMcpManager do
  import SweetXml, only: [sigil_x: 2]
  alias BetterNotion.Document

  @moduledoc """
  Manages the lifecycle of a McpClient connected to Notion's MCP server.

  Sits in the supervision tree and provides two modes:

  - `:stalled` — No valid token. Incoming requests are queued (callers block).
    An authentication flow runs in the background. Once auth completes,
    the MCP client is started and queued requests are replayed.

  - `:connected` — MCP client is up. Requests are forwarded to the client.
    If a 401 / auth error is detected, transitions back to `:stalled`,
    re-authenticates, and replays any queued requests.
  """

  use GenServer
  require Logger

  @notion_mcp_url "https://mcp.notion.com/mcp"

  # --- Public API ---

  @doc """
  Fetches a Notion document content by calling the appropriate tool on the MCP server.
  It returns the content of the document as a markdown formatted string.
  """
  @spec fetch_document(String.t()) :: {:ok, String.t()} | {:error, any()}
  def fetch_document(page_id) do
    with {:ok, result} <- call_tool("notion-fetch", %{"id" => page_id}) do
      Regex.scan(~r/<content>(.*?)<\/content>/s, fetch_text(result), capture: :all_but_first)
      |> List.flatten()
      |> Enum.join("\n")
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches a Notion document properties by calling the appropriate tool on the MCP server.
  It returns the properties of the document as a JSON formatted string.
  """
  @spec fetch_properties(String.t()) :: {:ok, String.t()} | {:error, any()}
  def fetch_properties(page_id) do
    with {:ok, result} <- call_tool("notion-fetch", %{"id" => page_id}) do
      Regex.scan(~r/<properties>(.*?)<\/properties>/s, fetch_text(result),
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.join("\n")
      |> then(&{:ok, &1})
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches entries from a Notion database view by its URL.

  Returns the filtered results based on the view's display properties,
  along with metadata about whether more results are available and which
  fields were excluded.
  """
  @spec fetch_view_entries(String.t()) ::
          {:ok,
           %{
             has_more: boolean(),
             results: [map()],
             other_fields: [String.t()],
             view_info: map()
           }}
          | {:error, any()}
  def fetch_view_entries(view_url) do
    with {:ok, database_result} <-
           call_tool("notion-fetch", %{"id" => Document.extract_page_id(view_url)}),
         {:ok, view_results} <- call_tool("notion-query-database-view", %{"view_url" => view_url}),
         {:ok, view_info} <- extract_view_info(database_result, view_url) do
      filter_view_results(view_results, view_info)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_view_info(database_result, view_url) do
    view_info =
      Regex.scan(~r/<views>(.*?)<\/views>/s, fetch_text(database_result),
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.join("\n")
      |> then(&"<views>#{&1}</views>")
      |> SweetXml.xpath(~x"//views/view"l,
        url: ~x"./@url"s,
        content: ~x"./text()"s |> SweetXml.transform_by(&Jason.decode!/1)
      )
      |> Enum.find(fn %{url: url} ->
        # view URL ressemble {{view://318a8f8d-e3be-8012-bd22-000cae97f8a0}} so we want to regex scan first
        view_id =
          Regex.scan(~r/{{(.*?)}}/, url, capture: :all_but_first)
          |> List.flatten()
          |> List.first()
          |> URI.parse()
          |> Map.get(:host)
          |> String.replace("-", "")

        view_id == Document.extract_view_id(view_url)
      end)

    case view_info do
      nil -> {:error, :view_not_found}
      %{content: content} -> {:ok, content}
    end
  end

  defp filter_view_results(view_results, view_info) do
    %{"has_more" => has_more?, "results" => results} =
      view_results["content"] |> Enum.at(0) |> Map.get("text") |> Jason.decode!()

    fields_to_send =
      (view_info["displayProperties"] ++ List.wrap(view_info["timelineBy"]) ++ ["url"])
      |> Enum.uniq()

    other_fields =
      results
      |> List.first()
      |> case do
        nil -> []
        entry -> Map.keys(entry)
      end
      |> Enum.filter(&(&1 not in fields_to_send))

    results =
      results
      |> Enum.map(
        &Map.filter(&1, fn {k, _v} ->
          Enum.find(fields_to_send, fn field -> String.contains?(k, field) end) != nil
        end)
      )

    {:ok,
     %{has_more: has_more?, results: results, other_fields: other_fields, view_info: view_info}}
  end

  defp fetch_text(result) do
    result["content"] |> Enum.at(0) |> Map.get("text") |> Jason.decode!() |> Map.get("text")
  end

  @doc """
  Updates a Notion document content by calling the appropriate tool on the MCP server.
  The `updates` argument is a list of maps with the following structure:
  ```
  %{
    old_str: "string to be replaced",
    new_str: "string to replace with"
  }
  ```
  """
  @spec update_page(String.t(), list(%{old_str: String.t(), new_str: String.t()})) ::
          {:ok, any()} | {:error, any()}
  def update_page(page_id, updates) do
    args = %{
      "page_id" => page_id,
      "command" => "update_content",
      "content_updates" => updates
    }

    call_tool("notion-update-page", args)
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List available tools from the Notion MCP server. Blocks if not yet authenticated."
  @spec list_tools(timeout()) :: {:ok, any()} | {:error, any()}
  def list_tools(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :list_tools, timeout)
  end

  @doc "Call a tool on the Notion MCP server. Blocks if not yet authenticated."
  @spec call_tool(String.t(), map(), timeout()) :: {:ok, any()} | {:error, any()}
  def call_tool(name, args, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:call_tool, name, args}, timeout)
  end

  @doc "Returns the current manager status."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    state = %{
      mode: :stalled,
      client: nil,
      client_monitor: nil,
      queue: [],
      auth_ref: nil
    }

    {:ok, state, {:continue, :check_auth}}
  end

  @impl true
  def handle_continue(:check_auth, state) do
    case BetterNotion.TokenStore.get_access_token() do
      {:ok, _token} ->
        {:noreply, try_connect(state)}

      {:error, _reason} ->
        {:noreply, start_auth(state)}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{mode: state.mode, has_client: state.client != nil}, state}
  end

  # Stalled: queue the request, caller blocks until auth + replay
  def handle_call(request, from, %{mode: :stalled} = state)
      when request == :list_tools or
             (is_tuple(request) and tuple_size(request) == 3 and elem(request, 0) == :call_tool) do
    {:noreply, enqueue(state, from, request)}
  end

  # Connected: forward to McpClient
  def handle_call(request, from, %{mode: :connected} = state)
      when request == :list_tools or
             (is_tuple(request) and tuple_size(request) == 3 and elem(request, 0) == :call_tool) do
    case forward_request(state.client, request) do
      {:error, {:auth_required, _}} ->
        new_state =
          state
          |> stop_client()
          |> enqueue(from, request)
          |> start_auth()

        {:noreply, new_state}

      {:error, {:client_unavailable, _}} ->
        new_state =
          state
          |> stop_client()
          |> enqueue(from, request)
          |> start_auth()

        {:noreply, new_state}

      result ->
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info({:auth_complete, ref, result}, %{auth_ref: ref} = state) do
    case result do
      {:ok, _token} ->
        Logger.info("Authentication successful, connecting to Notion MCP server")
        {:noreply, try_connect(%{state | auth_ref: nil})}

      {:error, reason} ->
        Logger.error("Authentication failed: #{inspect(reason)}")
        state = flush_queue(state, {:error, :not_authenticated})
        {:noreply, %{state | auth_ref: nil}}
    end
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, pid, reason},
        %{client: pid, client_monitor: monitor_ref} = state
      ) do
    Logger.warning("MCP client process died: #{inspect(reason)}")
    new_state = %{state | mode: :stalled, client: nil, client_monitor: nil}

    case reason do
      :normal ->
        {:noreply, new_state}

      _ ->
        {:noreply, start_auth(new_state)}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("NotionMcpManager received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  defp forward_request(client, request) do
    case request do
      :list_tools -> McpClient.list_tools(client)
      {:call_tool, name, args} -> McpClient.call_tool(client, name, args)
    end
  catch
    :exit, reason ->
      {:error, {:client_unavailable, reason}}
  end

  defp try_connect(state) do
    case McpClient.start_link(
           transport: {McpClient.Transport.Http, [url: @notion_mcp_url]},
           client_id: "BetterNotion"
         ) do
      {:ok, client} ->
        monitor_ref = Process.monitor(client)

        new_state = %{
          state
          | mode: :connected,
            client: client,
            client_monitor: monitor_ref
        }

        replay_queue(new_state)

      {:error, reason} ->
        Logger.error("Failed to start MCP client: #{inspect(reason)}")
        start_auth(state)
    end
  end

  defp start_auth(%{auth_ref: ref} = state) when ref != nil do
    # Auth already in progress, don't start another
    state
  end

  defp start_auth(state) do
    ref = make_ref()
    manager = self()

    spawn(fn ->
      result = BetterNotion.NotionAuth.ensure_authenticated()
      send(manager, {:auth_complete, ref, result})
    end)

    Logger.info("Authentication flow started")
    %{state | mode: :stalled, auth_ref: ref}
  end

  defp stop_client(%{client: nil} = state), do: state

  defp stop_client(%{client: client, client_monitor: monitor_ref} = state) do
    if monitor_ref, do: Process.demonitor(monitor_ref, [:flush])

    if Process.alive?(client) do
      try do
        McpClient.stop(client)
      catch
        :exit, _ -> :ok
      end
    end

    %{state | client: nil, client_monitor: nil, mode: :stalled}
  end

  defp enqueue(state, from, request) do
    %{state | queue: state.queue ++ [{from, request}]}
  end

  defp replay_queue(%{queue: []} = state), do: state

  defp replay_queue(%{queue: [{from, request} | rest]} = state) do
    case forward_request(state.client, request) do
      {:error, {:auth_required, _}} ->
        state
        |> Map.put(:queue, [{from, request} | rest])
        |> stop_client()
        |> start_auth()

      {:error, {:client_unavailable, _}} ->
        state
        |> Map.put(:queue, [{from, request} | rest])
        |> stop_client()
        |> start_auth()

      result ->
        GenServer.reply(from, result)
        replay_queue(%{state | queue: rest})
    end
  end

  defp flush_queue(state, reply) do
    for {from, _request} <- state.queue do
      GenServer.reply(from, reply)
    end

    %{state | queue: []}
  end
end
