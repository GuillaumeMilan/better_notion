defmodule McpClient.Transport.Http do
  @moduledoc """
  HTTP transport implementation for MCP protocol using persistent SSE connections.

  This transport implements the MCP over HTTP using Server-Sent Events (SSE)
  for streaming responses as specified in the MCP HTTP transport specification.
  The transport runs as a GenServer process that maintains persistent connections
  and handles bidirectional communication.

  ## Architecture

  - **Connection Lifecycle**: Establishes new connection for each request, closing previous ones
  - **SSE Streams**: Maintains persistent SSE connections to receive server-initiated messages
  - **Bidirectional**: Supports both client requests and server-initiated messages
  - **Authentication**: Integrates with auth modules for credential management

  ## Configuration

  The HTTP transport accepts the following options:

  - `:client` - Required. PID of the MCP client process for forwarding server messages
  - `:url` - The base URL of the MCP server (required)
  - `:headers` - Additional HTTP headers to send (default: %{})
  - `:timeout` - Request timeout in milliseconds (default: 30_000)
  - `:ssl_options` - SSL options for HTTPS connections (default: [])
  - `:follow_redirect` - Whether to follow redirects (default: true)
  - `:max_redirect` - Maximum number of redirects to follow (default: 5)

  ## Example

      {:ok, transport_pid} = McpClient.Transport.Http.start_link([
        client: self(),
        url: "https://api.example.com/mcp",
        headers: %{
          "User-Agent" => "MyApp/1.0",
          "Accept" => "text/event-stream"
        },
        timeout: 60_000,
        ssl_options: [verify: :verify_peer]
      ])

      # Send a request
      {:ok, response} = GenServer.call(transport_pid, {:send_request, request})
  """

  use McpClient.Transport

  require Logger

  @default_timeout 30_000
  @default_headers %{
    "Content-Type" => "application/json",
    "Accept" => "text/event-stream",
    "Cache-Control" => "no-cache"
  }

  @type connection_state :: %{
          status: :waiting_code | :waiting_headers | :streaming_response | :keepalive,
          buffer: String.t(),
          type: :sse | :json | nil,
          # TODO the request must be uniq so the client can identify it
          request: map()
        }

  @typedoc "HTTP transport GenServer state"
  @type state :: %{
          client: pid(),
          url: String.t(),
          headers: map(),
          timeout: non_neg_integer(),
          ssl_options: keyword(),
          follow_redirect: boolean(),
          max_redirect: non_neg_integer(),
          connections: %{:hackney.client_ref() => connection_state()},
          cookies: [String.t()],
          mcp_session_id: String.t() | nil
        }

  ## GenServer Callbacks

  @impl McpClient.Transport
  def init_transport(opts) do
    with {:ok, client} <- get_required_opt(opts, :client),
         {:ok, url} <- get_required_opt(opts, :url),
         {:ok, parsed_url} <- validate_url(url) do
      state = %{
        client: client,
        url: parsed_url,
        headers: build_headers(opts),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        ssl_options: Keyword.get(opts, :ssl_options, []),
        follow_redirect: Keyword.get(opts, :follow_redirect, true),
        max_redirect: Keyword.get(opts, :max_redirect, 5),
        connections: %{},
        cookies: [],
        mcp_session_id: nil
      }

      Logger.debug("HTTP transport initialized with URL: #{state.url}")
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("Failed to initialize HTTP transport: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl McpClient.Transport
  def handle_request(request, state) do
    # Close existing connection in keepalive state with empty buffer
    with {:ok, state} <- close_keepalive_connections(state),
         # Also reset SSE buffer for new request
         {:ok, body} <- encode_request(request),
         {:ok, state} <- do_http_request(state, request, body) do
      Logger.debug("Sent HTTP request: #{inspect(request)}")
      {:ok, state}
    else
      {:error, reason} ->
        Logger.error("Failed to send HTTP request: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl McpClient.Transport
  def handle_message({:hackney_response, ref, {:status, status_code, _reason}}, state) do
    with %{status: :waiting_code} = connection_state <- state.connections[ref] do
      case status_code do
        200 ->
          connection_state = %{connection_state | status: :waiting_headers}
          {:ok, update_connection_state(state, ref, connection_state)}

        401 ->
          Logger.warning("Received 401 - authentication required")
          draining_responses(ref)
          notify_auth_required(state.client)
          state = may_send_error_to_client(state, ref, {:auth_required, %{}})
          {:ok, state}

        status_code ->
          Logger.warning("Received unexpected HTTP status code: #{status_code}")

          draining_responses(ref)

          state =
            may_send_error_to_client(
              state,
              ref,
              "Received unexpected HTTP status code: #{status_code}"
            )

          {:ok, state}
      end
    else
      _ ->
        state =
          may_send_error_to_client(state, ref, "Received status on unknown or closed connection")

        {:ok, state}
    end
  end

  @impl McpClient.Transport
  def handle_message({:hackney_response, ref, {:headers, headers}}, state) do
    Logger.debug("Received HTTP headers: #{inspect(headers)}")

    with %{status: :waiting_headers} = connection_state <- state.connections[ref] do
      connection_type = get_content_type(headers)

      connection_state =
        %{connection_state | status: :streaming_response} |> set_connection_type(connection_type)

      state =
        state
        |> update_state_from_headers(headers)
        |> update_connection_state(ref, connection_state)

      {:ok, state}
    else
      _ ->
        state =
          may_send_error_to_client(state, ref, "Received headers on unknown or closed connection")

        {:ok, state}
    end
  end

  @impl McpClient.Transport
  def handle_message({:hackney_response, ref, data}, state) when is_binary(data) do
    Logger.debug("Received data: #{byte_size(data)} bytes")

    with %{status: :streaming_response} <- state.connections[ref] do
      {:ok, handle_connection_data(state, ref, data)}
    else
      _ ->
        Logger.warning(
          "Received unexpected data on unknown or closed connection #{inspect(data)}"
        )

        state =
          may_send_error_to_client(state, ref, "Received data on unknown or closed connection")

        {:ok, state}
    end
  end

  @impl McpClient.Transport
  def handle_message({:hackney_response, ref, :done}, state) do
    with %{status: status} when status in [:streaming_response, :keepalive] <-
           state.connections[ref] do
      state = emit_response(state, ref)
      {:ok, state}
    else
      _ ->
        state =
          may_send_error_to_client(
            state,
            ref,
            "Received connection closed on unknown or closed connection"
          )

        {:ok, state}
    end
  end

  @impl McpClient.Transport
  def handle_message({:hackney_response, ref, {:error, reason}}, state) do
    Logger.warning("HTTP connection error: #{inspect(reason)}")

    # Close the connection and notify client
    state = may_send_error_to_client(state, ref, map_error({:network_error, reason}))
    {:ok, state}
  end

  ## Private Functions

  defp close_connection(state, ref) do
    case Map.get(state.connections, ref) do
      nil ->
        state

      _ ->
        :hackney.close(ref)
        new_connections = Map.delete(state.connections, ref)
        %{state | connections: new_connections}
    end
  end

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    case uri.scheme do
      scheme when scheme in ["http", "https"] -> {:ok, url}
      _ -> {:error, {:invalid_url, "URL must use http or https scheme"}}
    end
  end

  defp validate_url(_), do: {:error, {:invalid_url, "URL must be a string"}}

  defp build_headers(opts) do
    custom_headers = Keyword.get(opts, :headers, %{})
    Map.merge(@default_headers, custom_headers)
  end

  defp do_http_request(state, request, body) do
    options =
      [
        timeout: state.timeout,
        follow_redirect: state.follow_redirect,
        max_redirect: state.max_redirect,
        ssl_options: state.ssl_options,
        # Keep connection alive for SSE
        recv_timeout: :infinity
      ] ++
        [:async]

    headers = Map.to_list(build_request_headers(state))

    case :hackney.request(:post, state.url, headers, body, options) do
      {:ok, client_ref} ->
        new_state = %{
          state
          | connections: Map.put(state.connections, client_ref, new_connection_state(request))
        }

        {:ok, new_state}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp build_request_headers(state) do
    headers = state.headers

    # Add cookies if we have any
    headers =
      if state.cookies != [] do
        cookie_header = Enum.join(state.cookies, "; ")
        Map.put(headers, "Cookie", cookie_header)
      else
        headers
      end

    # Add MCP session ID if we have one
    headers =
      if state.mcp_session_id do
        Map.put(headers, "Mcp-Session-Id", state.mcp_session_id)
      else
        headers
      end

    # Add auth token if available and not already set
    headers =
      if Map.has_key?(headers, "Authorization") do
        headers
      else
        case BetterNotion.TokenStore.get_access_token() do
          {:ok, token} -> Map.put(headers, "Authorization", "Bearer #{token}")
          _ -> headers
        end
      end

    # Add Accept header
    headers = Map.put(headers, "Accept", "application/json, text/event-stream")

    headers
  end

  defp update_state_from_headers(state, response_headers) do
    # Extract Set-Cookie headers
    cookies = extract_cookies(response_headers)

    # Extract MCP Session ID
    mcp_session_id = extract_mcp_session_id(response_headers)

    # Update state with new cookies and session ID
    updated_state = %{
      state
      | cookies: merge_cookies(state.cookies, cookies),
        mcp_session_id: mcp_session_id || state.mcp_session_id
    }

    if cookies != [] or mcp_session_id do
      Logger.debug(
        "Updated state with cookies: #{inspect(updated_state.cookies)}, session_id: #{inspect(updated_state.mcp_session_id)}"
      )
    end

    updated_state
  end

  defp extract_cookies(headers) do
    headers
    |> Enum.filter(fn {key, _value} ->
      String.downcase(key) == "set-cookie"
    end)
    |> Enum.map(fn {_key, value} -> value end)
  end

  defp extract_mcp_session_id(headers) do
    headers
    |> Enum.find(fn {key, _value} ->
      String.downcase(key) == "mcp-session-id"
    end)
    |> case do
      {_key, value} -> value
      nil -> nil
    end
  end

  defp merge_cookies(existing_cookies, new_cookies) do
    # For simplicity, we'll append new cookies to existing ones
    # In a production system, you might want to parse cookie names
    # and replace cookies with the same name
    existing_cookies ++ new_cookies
  end

  defp emit_response(state, ref) do
    connection_state = state.connections[ref]

    case connection_state.type do
      :see ->
        close_connection(state, ref)

      _ ->
        handle_json_response(state, ref)
    end
  end

  defp handle_connection_data(state, ref, data) do
    connection_state = state.connections[ref]
    new_buffer = connection_state.buffer <> data
    connection_state = %{connection_state | buffer: new_buffer}
    state = update_connection_state(state, ref, connection_state)

    case connection_state.type do
      :sse ->
        handle_sse_response(state, ref)

      :json ->
        state
    end
  end

  defp handle_sse_response(state, ref) do
    connection_state = state.connections[ref]
    buffer = connection_state.buffer
    {complete_events, remaining_buffer} = extract_complete_sse_events(buffer)
    connection_state = %{connection_state | buffer: remaining_buffer}
    state = update_connection_state(state, ref, connection_state)

    complete_events
    |> Enum.reduce_while(state, fn event, state ->
      connection_state = state.connections[ref]

      case process_sse_event(event) do
        {:ok, message} ->
          case connection_state.status do
            :streaming_response ->
              send_response(state.client, connection_state.request, message)
              connection_state = %{connection_state | status: :keepalive, request: nil}
              state = update_connection_state(state, ref, connection_state)
              {:cont, state}

            :keepalive ->
              send_event(state.client, message)
              {:cont, state}
          end

        :error ->
          {:halt,
           may_send_error_to_client(state, ref, "Failed to parse SSE event: #{inspect(event)}")}
      end
    end)
  end

  defp handle_json_response(state, ref) do
    connection_state = state.connections[ref]

    case parse_response(connection_state.buffer) do
      {:ok, response} ->
        send_response(state.client, connection_state.request, response)
        new_state = close_connection(state, ref)
        new_state

      {:error, reason} ->
        new_state = may_send_error_to_client(state, ref, {:parse_json_error, reason})
        new_state
    end
  end

  defp process_sse_event(%{data: data}) do
    case Jason.decode(data) do
      {:ok, message} -> {:ok, message}
      {:error, _reason} -> :error
    end
  end

  defp process_sse_event(_), do: :error

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {key, _value} ->
      String.downcase(key) == "content-type"
    end)
    |> case do
      {_key, value} ->
        value
        |> String.downcase()
        |> String.split(";")
        |> hd()
        |> String.trim()

      nil ->
        "application/json"
    end
  end

  defp extract_complete_sse_events(buffer) do
    # SSE events are separated by double newlines (\n\n)
    # Split buffer into potential events and incomplete data
    parts = String.split(buffer, "\n\n")

    cond do
      # If only one part and buffer doesn't end with double newline, everything is incomplete
      length(parts) == 1 and not String.ends_with?(buffer, "\n\n") ->
        {[], hd(parts)}

      # If buffer ends with double newline, all parts are complete
      String.ends_with?(buffer, "\n\n") ->
        complete_events =
          parts
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(&parse_sse_event/1)
          |> Enum.filter(&(&1 != nil))

        {complete_events, ""}

      # Otherwise, all but the last part are complete
      true ->
        {complete_parts, remaining} = {Enum.drop(parts, -1), List.last(parts)}

        complete_events =
          complete_parts
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(&parse_sse_event/1)
          |> Enum.filter(&(&1 != nil))

        {complete_events, remaining}
    end
  end

  defp parse_sse_event(event_data) do
    lines = String.split(event_data, "\n")

    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        ["data", data] ->
          existing_data = Map.get(acc, :data, "")
          Map.put(acc, :data, existing_data <> data <> "\n")

        ["event", event] ->
          Map.put(acc, :event, event)

        ["id", id] ->
          Map.put(acc, :id, id)

        ["retry", retry] ->
          Map.put(acc, :retry, retry)

        _ ->
          acc
      end
    end)
    |> case do
      %{data: data} = event ->
        # Clean up trailing newline from data
        %{event | data: String.trim_trailing(data, "\n")}

      _ ->
        nil
    end
  end

  defp parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:json_decode_error, reason}}
    end
  end

  defp new_connection_state(request) do
    %{
      status: :waiting_code,
      buffer: "",
      type: nil,
      request: request
    }
  end

  defp update_connection_state(state, ref, connection_state) do
    new_connections = Map.put(state.connections, ref, connection_state)
    %{state | connections: new_connections}
  end

  defp set_connection_type(connection_state, "text/event-stream"),
    do: %{connection_state | type: :sse}

  defp set_connection_type(connection_state, "application/json"),
    do: %{connection_state | type: :json}

  defp may_send_error_to_client(state, ref, message) do
    connection_state = state.connections[ref]

    Logger.debug(
      "Closing connection #{inspect(ref)} with error: #{inspect(message)} and connection_state: #{inspect(connection_state)}"
    )

    if connection_state do
      if connection_state.request do
        send_error(state.client, connection_state.request, message)
      end

      close_connection(state, ref)
    else
      :hackney.close(ref)
      state
    end
  end

  defp close_keepalive_connections(state) do
    keepalive_refs =
      state.connections
      |> Enum.filter(fn {_ref, conn_state} ->
        conn_state.status == :keepalive and conn_state.buffer == ""
      end)
      |> Enum.map(fn {ref, _conn_state} -> ref end)

    new_state =
      Enum.reduce(keepalive_refs, state, fn ref, acc_state ->
        close_connection(acc_state, ref)
      end)

    {:ok, new_state}
  end

  defp draining_responses(ref) do
    receive do
      {:hackney_response, ^ref, data} ->
        Logger.debug("Draining response data: #{inspect(data)}")
        draining_responses(ref)
    after
      1000 -> :ok
    end
  end

  # TODO Unused The pattern can never match the type.
  defp map_error({:auth_required, details}), do: {:auth_required, details}
  defp map_error({:network_error, reason}), do: {:network_error, reason}
  defp map_error({:http_error, details}), do: {:protocol_error, details}
  defp map_error({:json_encode_error, reason}), do: {:protocol_error, {:json_encode, reason}}
  defp map_error({:json_decode_error, reason}), do: {:protocol_error, {:json_decode, reason}}
  defp map_error({:sse_stream_error, reason}), do: {:protocol_error, {:sse_stream, reason}}
  defp map_error({:sse_error, reason}), do: {:protocol_error, {:sse, reason}}
  defp map_error({:response_body_error, reason}), do: {:protocol_error, {:response_body, reason}}
  defp map_error({:missing_required_option, key}), do: {:config_error, {:missing_option, key}}
  defp map_error({:invalid_url, reason}), do: {:config_error, {:invalid_url, reason}}
  defp map_error(reason), do: reason
end
