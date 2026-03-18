defmodule McpClient do
  use GenServer
  require Logger

  @default_timeout 30_000
  @default_protocol_version "2025-06-18"

  @moduledoc """
  A GenServer-based client for interacting with Model Context Protocol (MCP) servers.

  This module provides a complete implementation of the MCP client protocol, supporting
  multiple transport layers (HTTP with SSE, stdio, etc.) and handling the full lifecycle
  of MCP connections including initialization, tool discovery, and tool invocation.

  ## Features

  - **Multiple Transports**: Supports HTTP (with Server-Sent Events), stdio, and custom transports
  - **Automatic Initialization**: Handles MCP protocol handshake automatically
  - **Tool Discovery**: Query available tools from the server
  - **Tool Invocation**: Execute remote tools with type-safe arguments
  - **Session Management**: Maintains persistent connections and session state
  - **Error Handling**: Comprehensive error handling with detailed error types

  ## Architecture

  The client operates as a supervised GenServer process that:
  1. Manages a transport layer (HTTP, stdio, etc.)
  2. Performs the MCP initialization handshake
  3. Tracks pending requests and matches responses
  4. Forwards server-initiated events to handlers

  ## Transport Configuration

  The client requires a transport configuration tuple `{module, opts}` where:
  - `module` is the transport implementation (e.g., `McpClient.Transport.Http`)
  - `opts` is a keyword list of transport-specific options

  ### HTTP Transport Example

  ```elixir
  {:ok, client} = McpClient.start_link([
    transport: {McpClient.Transport.Http, [
      url: "https://api.example.com/mcp",
      headers: %{"Authorization" => "Bearer token123"},
      timeout: 60_000
    ]},
    client_id: "my-app",
    timeout: 30_000
  ])
  ```

  ## Usage Examples

  ### Basic HTTP Client Setup

  ```elixir
  # Start a client connected to an MCP server over HTTP
  {:ok, client} = McpClient.start_link([
    transport: {McpClient.Transport.Http, [
      url: "http://localhost:3000/mcp"
    ]},
    client_id: "my-application"
  ])

  # List available tools
  {:ok, tools} = McpClient.list_tools(client)
  # => {:ok, %{"tools" => [%{"name" => "search", ...}, ...]}}

  # Call a tool
  {:ok, result} = McpClient.call_tool(client, "search", %{
    "query" => "Elixir documentation",
    "limit" => 10
  })

  # Check client status
  {:ok, status} = McpClient.status(client)

  # Stop the client
  :ok = McpClient.stop(client)
  ```

  ### Supervised Client with Named Process

  ```elixir
  # In your application supervision tree
  children = [
    {McpClient, [
      name: MyApp.McpClient,
      transport: {McpClient.Transport.Http, [
        url: "https://api.example.com/mcp",
        headers: %{
          "Authorization" => "Bearer \#{Application.get_env(:my_app, :api_token)}"
        }
      ]},
      client_id: "my-app-v1.0"
    ]}
  ]

  # Later, call the named client
  {:ok, tools} = McpClient.list_tools(MyApp.McpClient)
  ```

  ### Advanced HTTP Configuration

  ```elixir
  {:ok, client} = McpClient.start_link([
    transport: {McpClient.Transport.Http, [
      url: "https://secure-api.example.com/mcp",
      headers: %{
        "Authorization" => "Bearer secret_token",
        "User-Agent" => "MyApp/1.0",
        "X-Custom-Header" => "value"
      },
      timeout: 120_000,
      ssl_options: [
        verify: :verify_peer,
        cacertfile: "/path/to/ca-bundle.crt",
        depth: 2
      ],
      follow_redirect: true,
      max_redirect: 3
    ]},
    client_id: "secure-client",
    protocol_version: "2025-06-18",
    timeout: 60_000
  ])
  ```

  ### Error Handling

  ```elixir
  case McpClient.call_tool(client, "process_data", %{"input" => data}) do
    {:ok, result} ->
      # Process successful result
      handle_result(result)

    {:error, %{"code" => -32602, "message" => message}} ->
      # Invalid params error from server
      Logger.error("Invalid parameters: \#{message}")

    {:error, {:network_error, reason}} ->
      # Network/transport error
      Logger.error("Network error: \#{inspect(reason)}")

    {:error, reason} ->
      # Other errors
      Logger.error("Error: \#{inspect(reason)}")
  end
  ```

  ### Working with Tool Results

  ```elixir
  {:ok, %{"tools" => tools}} = McpClient.list_tools(client)

  # Find a specific tool
  search_tool = Enum.find(tools, fn tool ->
    tool["name"] == "semantic_search"
  end)

  # Inspect tool schema
  IO.inspect(search_tool["inputSchema"])

  # Call the tool with validated arguments
  {:ok, result} = McpClient.call_tool(client, "semantic_search", %{
    "query" => "machine learning",
    "scope" => "documentation",
    "maxResults" => 20
  })
  ```

  ## Options

  - `:transport` - Required. Tuple of `{module, opts}` for transport configuration
  - `:client_id` - Optional. Client identifier sent during initialization
  - `:timeout` - Optional. Request timeout in milliseconds (default: 30,000)
  - `:protocol_version` - Optional. MCP protocol version (default: "2025-06-18")
  - `:name` - Optional. Registered name for the GenServer process

  ## HTTP Transport Options

  When using `McpClient.Transport.Http`, the following options are available:

  - `:url` - Required. The MCP server endpoint URL
  - `:headers` - Optional. Map of HTTP headers to include in requests
  - `:timeout` - Optional. HTTP request timeout in milliseconds (default: 30,000)
  - `:ssl_options` - Optional. SSL/TLS options for HTTPS connections
  - `:follow_redirect` - Optional. Whether to follow HTTP redirects (default: true)
  - `:max_redirect` - Optional. Maximum redirects to follow (default: 5)

  ## Return Values

  Most functions return:
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  Error reasons can be:
  - MCP protocol errors: Maps with "code" and "message" fields
  - Transport errors: `{:network_error, reason}`, `{:transport_error, reason}`
  - Protocol errors: `{:protocol_error, details}`
  - Configuration errors: `{:config_error, details}`

  ## Server-Initiated Messages

  The MCP protocol supports server-initiated messages (notifications, updates, etc.).
  Currently, these are logged but not forwarded to application code. Future versions
  may support registering handlers for specific message types.

  ## See Also

  - `McpClient.Transport` - Transport behavior and common utilities
  - `McpClient.Transport.Http` - HTTP transport implementation details
  """

  @doc """
  List available tools from the MCP server.

  Returns a list of tool definitions that can be called.

  ## Examples

  ```elixir
  {:ok, tools} = McpClient.list_tools(pid)
  # => {:ok, [%{"name" => "search", "description" => "Search function", ...}]}
  ```
  """
  @spec list_tools(GenServer.server()) :: {:ok, any()} | {:error, any()}
  @spec list_tools(GenServer.server(), integer() | :infinity) :: {:ok, any()} | {:error, any()}
  def list_tools(client_pid, timeout \\ 30_000) do
    GenServer.call(client_pid, :list_tools, timeout)
  end

  @doc """
  Call a specific tool on the MCP server.

  ## Parameters

  - `client` - The client PID
  - `tool_name` - Name of the tool to call
  - `arguments` - Map of arguments to pass to the tool

  ## Examples

  ```elixir
  {:ok, result} = McpClient.call_tool(pid, "search", %{query: "test"})
  # => {:ok, %{"results" => [...]}}
  ```
  """
  @spec call_tool(GenServer.server(), String.t(), map()) :: {:ok, any()} | {:error, any()}
  @spec call_tool(GenServer.server(), String.t(), map(), integer() | :infinity) ::
          {:ok, any()} | {:error, any()}
  def call_tool(client_pid, tool_name, input, timeout \\ 30_000) when is_map(input) do
    GenServer.call(client_pid, {:call_tool, tool_name, input}, timeout)
  end

  @doc """
  List available resources from the MCP server.
  """
  @spec list_resources(GenServer.server(), timeout()) :: {:ok, any()} | {:error, any()}
  def list_resources(client_pid, timeout \\ 30_000) do
    GenServer.call(client_pid, :list_resources, timeout)
  end

  @doc """
  Read a specific resource from the MCP server by URI.
  """
  @spec read_resource(GenServer.server(), String.t(), timeout()) :: {:ok, any()} | {:error, any()}
  def read_resource(client_pid, uri, timeout \\ 30_000) when is_binary(uri) do
    GenServer.call(client_pid, {:read_resource, uri}, timeout)
  end

  @doc """
  Get the current client status and connection state.
  """
  @spec status(GenServer.server()) :: {:ok, map()}
  def status(client) do
    GenServer.call(client, :status)
  end

  @doc """
  Stop the client gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(client) do
    GenServer.stop(client)
  end

  @typedoc "MCP request to be sent via the transport layer"
  @type request :: {reference(), map()}

  @typedoc "MCP response from the transport layer"
  @type response :: map()

  @typedoc "Error reason for recoverable errors"
  @type error_reason ::
          atom()
          | String.t()
          | {:protocol_error, any()}
          | {:transport_error, any()}

  @typep state :: %{
           transport_module: module(),
           transport_pid: pid(),
           client_id: String.t(),
           timeout: non_neg_integer(),
           protocol_version: String.t(),
           request_id_counter: integer(),
           requests: %{integer() => {GenServer.from(), reference()}}
         }
  @type tool_name :: String.t()

  @typep list_tools_request :: :list_tools
  @typep call_tool_request :: {:call_tool, tool_name(), input :: map()}
  @typep operation :: list_tools_request() | call_tool_request()

  @doc """
  Start an MCP client GenServer process and link it to the current process.

  This function initializes an MCP client with the specified transport layer and
  configuration options. The client will automatically perform the MCP initialization
  handshake with the server before being ready to accept requests.

  ## Options

  Required:
  - `:transport` - `{module, opts}` tuple specifying the transport implementation and its options

  Optional:
  - `:client_id` - String identifier for this client (sent to server during initialization)
  - `:timeout` - Request timeout in milliseconds (default: #{@default_timeout})
  - `:protocol_version` - MCP protocol version string (default: "#{@default_protocol_version}")
  - `:name` - Atom or `{:via, module, term}` for registering the process

  ## Transport Configuration

  The `:transport` option must be a tuple of `{module, transport_opts}` where:
  - `module` is a module implementing the `McpClient.Transport` behavior
  - `transport_opts` is a keyword list of transport-specific options

  ### HTTP Transport

  For HTTP-based MCP servers (the most common case):

  ```elixir
  transport: {McpClient.Transport.Http, [
    url: "https://api.example.com/mcp",  # Required
    headers: %{},                         # Optional
    timeout: 30_000,                      # Optional (milliseconds)
    ssl_options: [],                      # Optional
    follow_redirect: true,                # Optional
    max_redirect: 5                       # Optional
  ]}
  ```

  ## Examples

  ### Basic HTTP Client

  ```elixir
  {:ok, client} = McpClient.start_link([
    transport: {McpClient.Transport.Http, [
      url: "http://localhost:3000/mcp"
    ]}
  ])
  ```

  ### Client with Authentication

  ```elixir
  {:ok, client} = McpClient.start_link([
    transport: {McpClient.Transport.Http, [
      url: "https://api.example.com/mcp",
      headers: %{
        "Authorization" => "Bearer \#{api_token}",
        "X-API-Key" => api_key
      }
    ]},
    client_id: "my-application-v1.0"
  ])
  ```

  ### Named Client in Supervision Tree

  ```elixir
  # In your application.ex or supervisor
  children = [
    {McpClient, [
      name: MyApp.McpClient,
      transport: {McpClient.Transport.Http, [
        url: Application.get_env(:my_app, :mcp_url),
        headers: %{"Authorization" => "Bearer \#{get_token()}"}
      ]},
      client_id: "myapp",
      timeout: 60_000
    ]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)

  # Access the named client
  McpClient.list_tools(MyApp.McpClient)
  ```

  ### Client with Custom SSL Configuration

  ```elixir
  {:ok, client} = McpClient.start_link([
    transport: {McpClient.Transport.Http, [
      url: "https://secure-server.example.com/mcp",
      ssl_options: [
        verify: :verify_peer,
        cacertfile: "/etc/ssl/certs/ca-bundle.crt",
        depth: 2,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      timeout: 120_000
    ]},
    protocol_version: "2025-06-18"
  ])
  ```

  ### Multiple Clients to Different Servers

  ```elixir
  {:ok, search_client} = McpClient.start_link([
    name: MyApp.SearchMcpClient,
    transport: {McpClient.Transport.Http, [
      url: "https://search.example.com/mcp"
    ]},
    client_id: "search-client"
  ])

  {:ok, data_client} = McpClient.start_link([
    name: MyApp.DataMcpClient,
    transport: {McpClient.Transport.Http, [
      url: "https://data.example.com/mcp",
      headers: %{"Authorization" => "Bearer \#{data_token}"}
    ]},
    client_id: "data-client"
  ])

  # Use different clients for different purposes
  McpClient.call_tool(MyApp.SearchMcpClient, "search", %{"q" => "query"})
  McpClient.call_tool(MyApp.DataMcpClient, "fetch_data", %{"id" => 123})
  ```

  ## Return Values

  - `{:ok, pid}` - Successfully started and initialized the client
  - `{:error, reason}` - Failed to start or initialize the client

  Common error reasons:
  - `:missing_transport_config` - No `:transport` option provided
  - `{:invalid_transport_config, value}` - Invalid `:transport` format
  - `{:initialization_failed, error}` - MCP handshake failed with the server
  - `{:network_error, reason}` - Network or connection error during startup

  ## Notes

  - The process is linked to the caller, so if the caller crashes, the client will too
  - The client performs MCP initialization synchronously during startup
  - If initialization fails, the process will not start and an error is returned
  - All requests will timeout after the configured `:timeout` (default #{@default_timeout}ms)
  - The client maintains persistent connections for SSE-based HTTP transports

  ## See Also

  - `list_tools/1` - Discover available tools from the server
  - `call_tool/3` - Execute a tool on the server
  - `status/1` - Get client status information
  - `stop/1` - Gracefully stop the client
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_server_opts = get_gen_server_opts(opts)
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  ## GenServer Callbacks

  @impl GenServer
  def init(opts) do
    Logger.debug("Starting MCP client with options: #{inspect(opts)}")

    with {:ok, transport_module, transport_opts} <- get_transport_config(opts),
         {:ok, transport_pid} <- start_transport(transport_module, transport_opts) do
      state = %{
        transport_module: transport_module,
        transport_pid: transport_pid,
        client_id: Keyword.get(opts, :client_id, "VibersServer-Client"),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        protocol_version: Keyword.get(opts, :protocol_version, @default_protocol_version),
        request_id_counter: 0,
        requests: %{}
      }

      Logger.info("MCP client started successfully, initializing connection...")
      {:ok, state, {:continue, :initialize}}
    else
      {:error, reason} ->
        Logger.error("Failed to start MCP client: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:initialize, state) do
    Logger.debug("Performing MCP initialize handshake")

    params = %{
      protocolVersion: state.protocol_version,
      capabilities: %{
        tools: %{}
      }
    }

    params =
      if state.client_id do
        Map.put(params, :clientInfo, %{
          name: state.client_id,
          version: "0.1.0"
        })
      else
        params
      end

    {request_id, state} = generate_request_id(state)
    request = build_request("initialize", params, request_id)
    initialization_ref = send_request(state.transport_pid, request)

    receive do
      {McpClient.Transport, :response, ^initialization_ref, response} ->
        case extract_result(response) do
          {:ok, _result} ->
            Logger.info("MCP client initialized successfully")
            {:noreply, state}

          {:error, error} ->
            Logger.error("MCP initialization failed: #{inspect(error)}")
            {:stop, {:initialization_failed, error}, state}
        end

      {McpClient.Transport, :error, ^initialization_ref, response} ->
        raise "Unexpected error response during initialization: #{inspect(response)}"
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status = %{
      transport_module: state.transport_module,
      client_id: state.client_id,
      protocol_version: state.protocol_version,
      timeout: state.timeout
    }

    {:reply, {:ok, status}, state}
  end

  @impl GenServer
  def handle_call(operation, from, state) do
    if is_valid_operation?(operation) do
      {request_id, state} = generate_request_id(state)
      request = build_operation_request(operation, request_id)
      ref = send_request(state.transport_pid, request)
      state = %{state | requests: Map.put(state.requests, ref, from)}
      {:noreply, state}
    else
      {:reply, {:error, :invalid_operation}, state}
    end
  end

  @impl GenServer
  def handle_info({McpClient.Transport, :response, ref, response}, state) do
    Logger.debug("Received response for ref #{inspect(ref)}: #{inspect(response)}")

    case Map.pop(state.requests, ref) do
      {nil, _requests} ->
        Logger.error("[MCP Client] Received response for unknown reference: #{inspect(ref)}")
        {:noreply, state}

      {from, new_requests} ->
        case extract_result(response) do
          {:ok, result} ->
            GenServer.reply(from, {:ok, result})
            {:noreply, %{state | requests: new_requests}}

          {:error, error} ->
            GenServer.reply(from, {:error, error})
            {:noreply, %{state | requests: new_requests}}
        end
    end
  end

  @impl GenServer
  def handle_info({McpClient.Transport, :error, ref, reason}, state) do
    Logger.debug("Received error for ref #{inspect(ref)}: #{inspect(reason)}")

    case Map.pop(state.requests, ref) do
      {nil, _requests} ->
        Logger.error("[MCP Client] Received error for unknown reference: #{inspect(ref)}")
        {:noreply, state}

      {from, new_requests} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | requests: new_requests}}
    end
  end

  @impl GenServer
  def handle_info({McpClient.Transport, :event, message}, state) do
    Logger.debug("Received server-initiated message: #{inspect(message)}")

    # For now, just log the message. In a full implementation, this could:
    # - Update client state based on server notifications
    # - Forward messages to registered handlers
    # - Trigger callbacks for specific message types

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    Logger.debug("Received unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("MCP client terminating: #{inspect(reason)}")

    if Process.alive?(state.transport_pid) do
      GenServer.stop(state.transport_pid)
    end

    :ok
  end

  ## Private Functions

  defp start_transport(transport_module, transport_opts) do
    # Add client PID to transport options so transport can send server messages back
    transport_opts_with_client = Keyword.put(transport_opts, :client, self())
    transport_module.start_link(transport_opts_with_client)
  end

  defp get_gen_server_opts(opts) do
    case Keyword.get(opts, :name) do
      nil -> []
      name -> [name: name]
    end
  end

  defp get_transport_config(opts) do
    case Keyword.get(opts, :transport) do
      {module, transport_opts} when is_atom(module) and is_list(transport_opts) ->
        {:ok, module, transport_opts}

      nil ->
        {:error, :missing_transport_config}

      invalid ->
        {:error, {:invalid_transport_config, invalid}}
    end
  end

  @spec is_valid_operation?(operation()) :: boolean()
  def is_valid_operation?(:list_tools), do: true

  def is_valid_operation?({:call_tool, name, arguments})
      when is_binary(name) and is_map(arguments),
      do: true

  def is_valid_operation?(:list_resources), do: true

  def is_valid_operation?({:read_resource, uri})
      when is_binary(uri),
      do: true

  def is_valid_operation?(_), do: false

  @spec build_operation_request(atom(), integer()) :: map()
  defp build_operation_request(:list_tools, request_id) do
    build_request("tools/list", %{}, request_id)
  end

  defp build_operation_request({:call_tool, name, arguments}, request_id) do
    build_request("tools/call", %{"name" => name, "arguments" => arguments}, request_id)
  end

  defp build_operation_request(:list_resources, request_id) do
    build_request("resources/list", %{}, request_id)
  end

  defp build_operation_request({:read_resource, uri}, request_id) do
    build_request("resources/read", %{"uri" => uri}, request_id)
  end

  @spec build_request(String.t(), map(), integer()) :: map()
  defp build_request(method, params, request_id) do
    %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => method,
      "params" => params
    }
  end

  @spec generate_request_id(state()) :: {integer(), state()}
  defp generate_request_id(state) do
    {state.request_id_counter + 1, %{state | request_id_counter: state.request_id_counter + 1}}
  end

  @spec send_request(pid(), map()) :: reference()
  defp send_request(transport_pid, request) do
    ref = make_ref()
    send(transport_pid, {__MODULE__, :send_request, {ref, request}})
    ref
  end

  @spec extract_result(response()) :: {:ok, map()} | {:error, any()}
  defp extract_result(response) do
    case response do
      %{"result" => result} ->
        {:ok, result}

      %{"error" => error} ->
        {:error, error}

      invalid ->
        {:error, {:invalid_response, invalid}}
    end
  end
end
