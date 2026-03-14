defmodule McpClient.Transport do
  @moduledoc """
  Behavior for implementing MCP transport layers as GenServer processes.

  This behavior defines the contract that all transport implementations must follow
  to communicate with MCP servers. Transport layers are implemented as GenServer
  processes that handle persistent connections, bidirectional communication, and
  proper resource management.

  ## Architecture
  """

  @typedoc "Transport-specific options passed during initialization"
  @type opts :: keyword()

  @typedoc "MCP request message as a map"
  @type request :: {reference(), map()}

  @typedoc "MCP response message as a map"
  @type response :: map()

  @typedoc "Error reason for recoverable errors"
  @type error_reason ::
          atom()
          | String.t()
          | {:auth_required, map()}
          | {:protocol_error, any()}
          | {:transport_error, any()}

  @doc """
  Initialize the transport GenServer with given options.
  This callback is invoked during the GenServer `init/1` phase.

  See your transport's documentation for options.
  """
  @callback init_transport(opts()) :: {:ok, any()} | {:error, any()}

  @callback handle_request(request(), state :: any()) ::
              {:ok, state :: any()} | {:error, error_reason(), state :: any()}

  @doc """
  Handle incoming messages to the transport process that are not requests from the client.
  This can include messages from the underlying transport (e.g., HTTP responses,
  WebSocket messages, etc.) or other system messages.
  """
  @callback handle_message(message :: any(), state :: any()) ::
              {:ok, state :: any()} | {:error, error_reason()}

  # Default implementations using __using__ macro
  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour McpClient.Transport
      import McpClient.Transport

      # Default start_link implementation
      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end

      @impl GenServer
      def handle_info({McpClient, :send_request, request}, state) do
        case handle_request(request, state.transport_state) do
          {:ok, new_transport_state} ->
            {:noreply, %{state | transport_state: new_transport_state}}

          {:error, reason, new_transport_state} ->
            # Notify client of the error
            send_error(state.client, request, {:transport_error, reason})
            {:noreply, %{state | transport_state: new_transport_state}}

          unexpected ->
            require Logger
            Logger.error("Unexpected return from handle_request: #{inspect(unexpected)}")
            {:stop, {:error, :unexpected_return}, state}
        end
      end

      # TODO Unused can never match
      def handle_info(message, state) do
        case handle_message(message, state.transport_state) do
          {:ok, new_transport_state} ->
            {:noreply, %{state | transport_state: new_transport_state}}

          {:error, reason} ->
            {:stop, {:error, reason}, state}

          unexpected ->
            require Logger
            Logger.error("Unexpected return from handle_message: #{inspect(unexpected)}")
            {:stop, {:error, :unexpected_return}, state}
        end
      end

      @impl GenServer
      def init(opts) do
        with {:ok, client} <- get_required_opt(opts, :client),
             {:ok, transport_state} <- init_transport(opts) do
          {:ok, %{transport_state: transport_state, client: client}}
        else
          {:error, reason} -> {:stop, {:error, reason}}
        end
      end
    end
  end

  @doc """
  Helper to fetch a required option from keyword list.

  ## Example
      iex> opts = [url: "http://example.com", timeout: 5000]
      iex> McpClient.Transport.get_required_opt(opts, :url)
      {:ok, "http://example.com"}
      iex> McpClient.Transport.get_required_opt(opts, :missing)
      {:error, {:missing_required_option, :missing}}
  """
  @spec get_required_opt(opts(), atom()) ::
          {:ok, any()} | {:error, {:missing_required_option, atom()}}
  def get_required_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {:error, {:missing_required_option, key}}
      {:ok, value} -> {:ok, value}
    end
  end

  @doc """
  Send a response back to the client process.
  """
  @spec send_response(pid(), McpClient.Transport.request(), McpClient.Transport.response()) ::
          :ok
  def send_response(client_pid, {ref, _}, response) do
    send(client_pid, {__MODULE__, :response, ref, response})
    :ok
  end

  @doc """
  Send a server initiated event back to the client process.
  """
  @spec send_event(pid(), map()) :: :ok
  def send_event(client_pid, event) do
    send(client_pid, {__MODULE__, :event, event})
    :ok
  end

  @doc """
  Send an error notification back to the client process.
  """
  @spec send_error(pid(), McpClient.Transport.request(), McpClient.Transport.error_reason()) ::
          :ok
  def send_error(client_pid, {ref, _}, reason) do
    send(client_pid, {__MODULE__, :error, ref, reason})
    :ok
  end

  @doc """
  Send authentication request
  """
  @spec notify_auth_required(pid()) :: :ok
  def notify_auth_required(client_pid) do
    send(client_pid, {__MODULE__, :auth_required})
    :ok
  end

  @doc """
  Encode the request map to JSON string.
  """
  @spec encode_request(McpClient.Transport.request()) ::
          {:ok, String.t()} | {:error, {:json_encode_error, any()}}
  def encode_request({_, request_content}) do
    case Jason.encode(request_content) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encode_error, reason}}
    end
  end
end
