defmodule BetterNotion.TokenStore do
  @moduledoc """
  GenServer that manages OAuth token persistence and temporary OAuth state storage.

  Tokens are cached in-memory and persisted to a JSON file on disk.
  Temporary OAuth state (PKCE params, state strings) is stored in an ETS table
  with a 10-minute TTL for security.
  """

  use GenServer
  require Logger

  @oauth_states_table :better_notion_oauth_states
  @state_ttl_seconds 600
  @cleanup_interval_ms 60_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current access token if valid, or an error."
  @spec get_access_token() :: {:ok, String.t()} | {:error, :expired | :not_authenticated}
  def get_access_token do
    GenServer.call(__MODULE__, :get_access_token)
  end

  @doc "Returns the full token map or nil."
  @spec get_tokens() :: map() | nil
  def get_tokens do
    GenServer.call(__MODULE__, :get_tokens)
  end

  @doc "Stores tokens (from OAuth token exchange or refresh). Computes expires_at from expires_in."
  @spec store_tokens(map()) :: :ok
  def store_tokens(token_data) do
    GenServer.call(__MODULE__, {:store_tokens, token_data})
  end

  @doc "Clears stored tokens (e.g., on auth failure)."
  @spec clear_tokens() :: :ok
  def clear_tokens do
    GenServer.call(__MODULE__, :clear_tokens)
  end

  @doc "Store temporary OAuth state (PKCE params, state, client_info, discovery_info) with TTL."
  @spec store_oauth_state(String.t(), map()) :: :ok
  def store_oauth_state(state_key, state_data) do
    expires_at = System.system_time(:second) + @state_ttl_seconds
    :ets.insert(@oauth_states_table, {state_key, state_data, expires_at})
    :ok
  end

  @doc "Retrieve and validate temporary OAuth state by state key."
  @spec get_oauth_state(String.t()) ::
          {:ok, map()} | {:error, :state_not_found | :state_expired}
  def get_oauth_state(state_key) do
    case :ets.lookup(@oauth_states_table, state_key) do
      [{^state_key, state_data, expires_at}] ->
        if System.system_time(:second) < expires_at do
          {:ok, state_data}
        else
          :ets.delete(@oauth_states_table, state_key)
          {:error, :state_expired}
        end

      [] ->
        {:error, :state_not_found}
    end
  end

  @doc "Delete temporary OAuth state after successful use."
  @spec delete_oauth_state(String.t()) :: :ok
  def delete_oauth_state(state_key) do
    :ets.delete(@oauth_states_table, state_key)
    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    token_path =
      Keyword.get(opts, :token_path) ||
        Application.get_env(:better_notion, :token_path, default_token_path())

    # Create ETS table for temporary OAuth states
    :ets.new(@oauth_states_table, [:named_table, :public, :set])

    # Load tokens from file if they exist
    tokens = load_tokens_from_file(token_path)

    schedule_cleanup()

    {:ok, %{tokens: tokens, file_path: token_path}}
  end

  @impl true
  def handle_call(:get_access_token, _from, state) do
    result =
      case state.tokens do
        nil ->
          {:error, :not_authenticated}

        %{"access_token" => token} = tokens ->
          if token_expired?(tokens) do
            {:error, :expired}
          else
            {:ok, token}
          end
      end

    {:reply, result, state}
  end

  def handle_call(:get_tokens, _from, state) do
    {:reply, state.tokens, state}
  end

  def handle_call({:store_tokens, token_data}, _from, state) do
    tokens = normalize_tokens(token_data)
    write_tokens_to_file(tokens, state.file_path)
    {:reply, :ok, %{state | tokens: tokens}}
  end

  def handle_call(:clear_tokens, _from, state) do
    File.rm(state.file_path)
    {:reply, :ok, %{state | tokens: nil}}
  end

  @impl true
  def handle_info(:cleanup_expired_states, state) do
    now = System.system_time(:second)

    :ets.foldl(
      fn {key, _data, expires_at}, _acc ->
        if now >= expires_at, do: :ets.delete(@oauth_states_table, key)
        :ok
      end,
      :ok,
      @oauth_states_table
    )

    schedule_cleanup()
    {:noreply, state}
  end

  # --- Private Helpers ---

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired_states, @cleanup_interval_ms)
  end

  defp default_token_path do
    Path.join(System.user_home!(), ".better_notion/notion_tokens.json")
  end

  defp token_expired?(%{"expires_at" => expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _} -> DateTime.compare(DateTime.utc_now(), dt) != :lt
      _ -> true
    end
  end

  defp token_expired?(_), do: true

  defp normalize_tokens(token_data) do
    expires_at =
      case token_data["expires_in"] do
        seconds when is_integer(seconds) ->
          DateTime.utc_now()
          |> DateTime.add(seconds, :second)
          |> DateTime.to_iso8601()

        _ ->
          token_data["expires_at"]
      end

    Map.put(token_data, "expires_at", expires_at)
  end

  defp load_tokens_from_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, tokens} ->
            Logger.info("Loaded OAuth tokens from #{path}")
            tokens

          {:error, _} ->
            Logger.warning("Failed to decode tokens file at #{path}")
            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp write_tokens_to_file(tokens, path) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.write!(path, Jason.encode!(tokens, pretty: true))
    Logger.info("Saved OAuth tokens to #{path}")
  end
end
