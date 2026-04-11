defmodule McpClient.Transport.Stdio do
  @moduledoc """
  STDIO transport for MCP (Model Context Protocol).

  Spawns a subprocess and communicates over stdin/stdout using
  newline-delimited JSON-RPC messages.

  ## Options

  Required:
  - `:command` - The executable to spawn (e.g. `"npx"`, `"python"`)

  Optional:
  - `:args` - List of string arguments (default: `[]`)
  - `:env` - List of `{String.t(), String.t()}` environment variable tuples (default: `[]`)
  - `:cd` - Working directory for the subprocess (default: inherits parent)

  ## Example

      McpClient.start_link(
        transport: {McpClient.Transport.Stdio, [
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-everything"]
        ]}
      )
  """

  use McpClient.Transport
  require Logger

  @impl McpClient.Transport
  def init_transport(opts) do
    with {:ok, client} <- get_required_opt(opts, :client),
         {:ok, command} <- get_required_opt(opts, :command),
         {:ok, executable} <- resolve_command(command) do
      args = Keyword.get(opts, :args, [])
      env = opts |> Keyword.get(:env, []) |> encode_env()
      cd = Keyword.get(opts, :cd, nil)

      port_opts =
        [:binary, :exit_status, :use_stdio, {:args, args}, {:env, env}]
        |> maybe_add_cd(cd)

      port = Port.open({:spawn_executable, executable}, port_opts)

      {:ok,
       %{
         port: port,
         buffer: "",
         pending: %{},
         client: client
       }}
    end
  end

  @impl McpClient.Transport
  def handle_request({ref, request_map} = request, state) do
    case encode_request(request) do
      {:ok, json} ->
        Port.command(state.port, json <> "\n")
        pending = Map.put(state.pending, request_map["id"], {ref, request_map})
        {:ok, %{state | pending: pending}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl McpClient.Transport
  def handle_message({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {lines, remainder} = split_lines(buffer)
    state = %{state | buffer: remainder}

    state =
      Enum.reduce(lines, state, fn line, acc ->
        dispatch_line(line, acc)
      end)

    {:ok, state}
  end

  def handle_message({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("STDIO transport subprocess exited with status #{status}")

    Enum.each(state.pending, fn {_id, {ref, request_map}} ->
      send_error(state.client, {ref, request_map}, {:transport_error, {:process_exited, status}})
    end)

    {:error, {:process_exited, status}}
  end

  def handle_message(message, state) do
    Logger.debug("STDIO transport received unexpected message: #{inspect(message)}")
    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    port = state.transport_state.port

    if Port.info(port) != nil do
      Port.close(port)
    end

    :ok
  end

  ## Private helpers

  defp resolve_command(command) do
    case System.find_executable(command) do
      nil -> {:error, {:command_not_found, command}}
      path -> {:ok, path}
    end
  end

  defp encode_env(env) do
    Enum.map(env, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp maybe_add_cd(opts, nil), do: opts
  defp maybe_add_cd(opts, cd), do: opts ++ [{:cd, cd}]

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [incomplete] ->
        {[], incomplete}

      parts ->
        {complete, [remainder]} = Enum.split(parts, -1)
        {Enum.filter(complete, &(&1 != "")), remainder}
    end
  end

  defp dispatch_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = response} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            Logger.warning("Received response for unknown request id: #{inspect(id)}")
            state

          {{ref, request_map}, pending} ->
            send_response(state.client, {ref, request_map}, response)
            %{state | pending: pending}
        end

      {:ok, notification} ->
        send_event(state.client, notification)
        state

      {:error, reason} ->
        Logger.warning("Failed to decode JSON from subprocess: #{inspect(reason)}")
        state
    end
  end
end
