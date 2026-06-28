defmodule BetterNotion.NotionMcpManager do
  import SweetXml, only: [sigil_x: 2]
  alias BetterNotion.Document
  alias BetterNotion.FilterSolver

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
      |> Jason.decode()
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
  @spec fetch_view_entries(String.t(), [String.t()]) ::
          {:ok,
           %{
             has_more: boolean(),
             results: [map()],
             view_info: map(),
             other_fields: [String.t()]
           }}
          | {:error, any()}
  def fetch_view_entries(view_url, additional_fields \\ []) do
    with {:ok, database_result} <-
           call_tool("notion-fetch", %{"id" => Document.extract_page_id(view_url)}),
         {:ok, view_results} <-
           call_tool("notion-query-database-view", %{"view_url" => view_url}),
         {:ok, view_info} <- extract_view_info(database_result, view_url) do
      filter_view_results(view_results, view_info, additional_fields)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_view_info(database_result, view_url) do
    view_info =
      Regex.scan(~r/<views>(.*?)<\/views>/s, fetch_text(database_result), capture: :all_but_first)
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

  defp filter_view_results(view_results, view_info, additional_fields) do
    %{"has_more" => has_more?, "results" => results} =
      view_results["content"] |> Enum.at(0) |> Map.get("text") |> Jason.decode!()

    fields_to_send =
      (view_info["displayProperties"] ++
         List.wrap(view_info["timelineBy"]) ++ additional_fields ++ ["url"])
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

  @doc """
  Resolves a view URL to the context needed to create a page that lands in it.

  Returns the view's data source id, the data source `schema`, the view's
  `simpleFilters`, and the name of the title property.

  Note: the data source id is taken from the view config's `dataSourceUrl`,
  and the schema is fetched with a *separate* `notion-fetch` on that id — a
  fetch of the database page may surface a different embedded data source.
  """
  @spec get_view_context(String.t()) ::
          {:ok,
           %{
             data_source_id: String.t(),
             schema: map(),
             filters: [map()],
             title_property: String.t()
           }}
          | {:error, any()}
  def get_view_context(view_url) do
    with {:ok, database_result} <-
           call_tool("notion-fetch", %{"id" => Document.extract_page_id(view_url)}),
         {:ok, view_info} <- extract_view_info(database_result, view_url),
         {:ok, data_source_id} <- data_source_id_from_view(view_info),
         {:ok, ds_result} <- call_tool("notion-fetch", %{"id" => data_source_id}),
         {:ok, schema} <- extract_data_source_schema(ds_result),
         {:ok, title_property} <- find_title_property(schema) do
      {:ok,
       %{
         data_source_id: data_source_id,
         schema: schema,
         filters: view_info["simpleFilters"] || [],
         title_property: title_property
       }}
    end
  end

  @doc """
  Creates a page in a view's data source whose properties satisfy the view's
  filters, so the page appears in the view.

  Filters that cannot be auto-satisfied are skipped and returned in `warnings`;
  the page is still created. The title is written to the data source's title
  property (its name varies per data source).
  """
  @spec create_page_on_view(String.t(), String.t()) ::
          {:ok, %{page_id: String.t(), url: String.t(), warnings: [String.t()]}}
          | {:error, any()}
  def create_page_on_view(view_url, title \\ "New page") do
    with {:ok, ctx} <- get_view_context(view_url),
         {properties, warnings} <- FilterSolver.solve(ctx.filters, ctx.schema),
         properties = Map.put(properties, ctx.title_property, title),
         {:ok, %{page_id: page_id, url: url}} <- create_page(ctx.data_source_id, properties) do
      {:ok, %{page_id: page_id, url: url, warnings: warnings}}
    end
  end

  @doc """
  Creates a single page under a data source with the given flat property map.
  """
  @spec create_page(String.t(), map()) ::
          {:ok, %{page_id: String.t(), url: String.t()}} | {:error, any()}
  def create_page(data_source_id, properties) when is_map(properties) do
    args = %{
      "parent" => %{"type" => "data_source_id", "data_source_id" => data_source_id},
      "pages" => [%{"properties" => properties}]
    }

    with {:ok, result} <- call_tool("notion-create-pages", args) do
      case result do
        %{"isError" => true, "content" => [%{"text" => text} | _]} ->
          {:error, text}

        _ ->
          parse_created_page(result)
      end
    end
  end

  defp data_source_id_from_view(view_info) do
    case view_info["dataSourceUrl"] do
      url when is_binary(url) ->
        id =
          Regex.scan(~r/{{(.*?)}}/, url, capture: :all_but_first)
          |> List.flatten()
          |> List.first()
          |> case do
            nil -> nil
            token -> token |> URI.parse() |> Map.get(:host)
          end

        if id, do: {:ok, id}, else: {:error, :data_source_url_invalid}

      _ ->
        {:error, :data_source_url_missing}
    end
  end

  defp extract_data_source_schema(ds_result) do
    case Regex.run(~r/<data-source-state>\n(.*?)\n<\/data-source-state>/s, fetch_text(ds_result)) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, %{"schema" => schema}} when is_map(schema) -> {:ok, schema}
          _ -> {:error, :schema_not_found}
        end

      _ ->
        {:error, :schema_not_found}
    end
  end

  defp find_title_property(schema) do
    case Enum.find(schema, fn {_name, prop} -> prop["type"] == "title" end) do
      {name, _prop} -> {:ok, name}
      nil -> {:error, :title_property_not_found}
    end
  end

  defp parse_created_page(result) do
    with text when is_binary(text) <- get_in(result, ["content", Access.at(0), "text"]),
         {:ok, %{"pages" => [%{"id" => id, "url" => url} | _]}} <- Jason.decode(text) do
      {:ok, %{page_id: id, url: url}}
    else
      _ -> {:error, {:unexpected_create_response, result}}
    end
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

    with {:ok, result} <- call_tool("notion-update-page", args) do
      case result do
        %{"isError" => true, "content" => [%{"text" => text} | _]} ->
          {:error, text}

        _ ->
          {:ok, result}
      end
    end
  end

  @doc """
  Appends markdown `content` to the end of a Notion page.

  Uses the `notion-update-page` tool's `insert_content` command. This is the
  correct path when the page has no existing content to search-and-replace
  against: `update_content` matches `old_str` against the current page body, so
  an empty page (empty `old_str`) silently matches nothing and writes nothing.
  """
  @spec append_to_page(String.t(), String.t()) :: {:ok, any()} | {:error, any()}
  def append_to_page(page_id, content) do
    args = %{
      "page_id" => page_id,
      "command" => "insert_content",
      "content" => content,
      "position" => %{"type" => "end"}
    }

    with {:ok, result} <- call_tool("notion-update-page", args) do
      case result do
        %{"isError" => true, "content" => [%{"text" => text} | _]} ->
          {:error, text}

        _ ->
          {:ok, result}
      end
    end
  end

  @doc """
  Updates properties on a Notion page, and optionally its icon and/or cover.

  The `properties` argument is a map of property names to SQLite values
  (string, number, or null). Property names must match the exact names
  from the page's data source schema.

  Special property formats:
  - Date properties: use "date:{property}:start", "date:{property}:end", "date:{property}:is_datetime"
  - Checkbox properties: use "__YES__" / "__NO__"
  - Number properties: use plain numbers (not strings)
  - Properties named "id" or "url": prefix with "userDefined:"

  ## Icon and cover

  Pass `:icon` and/or `:cover` in `opts` to set them in the same call. They
  ride alongside the `update_properties` command, so an icon/cover-only update
  works with an empty `properties` map (omitting `properties` entirely would
  make the underlying tool reject the request).

  - `:icon` — an emoji character (e.g. "🚀"), a custom emoji by name
    (e.g. ":rocket_ship:"), or an external image URL. Use "none" to remove it.
  - `:cover` — an external image URL. Use "none" to remove it.

  A `nil` icon/cover is omitted, leaving the existing value unchanged.

  ## Examples

      # Update a select property
      update_properties(page_id, %{"Status*" => "In Progress"})

      # Update a date property
      update_properties(page_id, %{
        "date:Done at:start" => "2026-03-18",
        "date:Done at:is_datetime" => 0
      })

      # Set just the page emoji
      update_properties(page_id, %{}, icon: "🚀")

      # Update a property and the icon together
      update_properties(page_id, %{"Status*" => "Done"}, icon: "✅")
  """
  @spec update_properties(String.t(), map(), keyword()) :: {:ok, any()} | {:error, any()}
  def update_properties(page_id, properties, opts \\ []) when is_map(properties) do
    with {:ok, result} <-
           call_tool("notion-update-page", update_page_args(page_id, properties, opts)) do
      case result do
        %{"isError" => true, "content" => [%{"text" => text} | _]} ->
          {:error, text}

        _ ->
          {:ok, result}
      end
    end
  end

  @doc false
  # Builds the `notion-update-page` arguments for an `update_properties` call.
  # `:icon`/`:cover` are included only when provided (nil = leave unchanged).
  @spec update_page_args(String.t(), map(), keyword()) :: map()
  def update_page_args(page_id, properties, opts \\ []) do
    %{
      "page_id" => page_id,
      "command" => "update_properties",
      "properties" => properties
    }
    |> maybe_put("icon", Keyword.get(opts, :icon))
    |> maybe_put("cover", Keyword.get(opts, :cover))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  @doc "List available resources from the Notion MCP server."
  @spec list_resources(timeout()) :: {:ok, any()} | {:error, any()}
  def list_resources(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :list_resources, timeout)
  end

  @doc "Read a resource from the Notion MCP server by URI."
  @spec read_resource(String.t(), timeout()) :: {:ok, any()} | {:error, any()}
  def read_resource(uri, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:read_resource, uri}, timeout)
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
      when request in [:list_tools, :list_resources] or
             (is_tuple(request) and tuple_size(request) == 3 and elem(request, 0) == :call_tool) or
             (is_tuple(request) and tuple_size(request) == 2 and
                elem(request, 0) == :read_resource) do
    {:noreply, enqueue(state, from, request)}
  end

  # Connected: forward to McpClient
  def handle_call(request, from, %{mode: :connected} = state)
      when request in [:list_tools, :list_resources] or
             (is_tuple(request) and tuple_size(request) == 3 and elem(request, 0) == :call_tool) or
             (is_tuple(request) and tuple_size(request) == 2 and
                elem(request, 0) == :read_resource) do
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
        {:noreply, start_auth(%{state | auth_ref: nil})}
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
      :list_resources -> McpClient.list_resources(client)
      {:read_resource, uri} -> McpClient.read_resource(client, uri)
    end
  catch
    :exit, reason ->
      {:error, {:client_unavailable, reason}}
  end

  defp try_connect(state) do
    result =
      try do
        McpClient.start_link(
          transport: {McpClient.Transport.Http, [url: @notion_mcp_url]},
          client_id: "BetterNotion"
        )
      rescue
        e -> {:error, {:client_exception, e}}
      catch
        :exit, reason -> {:error, {:client_exit, reason}}
      end

    case result do
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
