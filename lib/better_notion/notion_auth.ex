defmodule BetterNotion.NotionAuth do
  @moduledoc """
  Core OAuth 2.1 logic for authenticating with Notion's MCP server.

  Implements:
  - RFC 8414 / RFC 9728 OAuth discovery
  - Dynamic client registration
  - PKCE (Proof Key for Code Exchange)
  - Authorization code exchange
  - Token refresh
  """

  require Logger

  @notion_mcp_url "https://mcp.notion.com"
  @callback_path "/oauth/callback"

  # --- Discovery ---

  @doc "Discovers OAuth endpoints from Notion's MCP server metadata."
  @spec discover_oauth_configuration() :: {:ok, map()} | {:error, any()}
  def discover_oauth_configuration do
    with {:ok, resource_meta} <- discover_protected_resource(),
         auth_server_url <- get_authorization_server(resource_meta),
         {:ok, server_meta} <- discover_authorization_server(auth_server_url) do
      {:ok,
       %{
         authorization_endpoint: server_meta["authorization_endpoint"],
         token_endpoint: server_meta["token_endpoint"],
         registration_endpoint: server_meta["registration_endpoint"],
         resource_metadata: resource_meta,
         server_metadata: server_meta
       }}
    end
  end

  defp discover_protected_resource do
    url = @notion_mcp_url <> "/.well-known/oauth-protected-resource"
    http_get(url)
  end

  defp discover_authorization_server(auth_server_url) do
    url = auth_server_url <> "/.well-known/oauth-authorization-server"
    http_get(url)
  end

  defp get_authorization_server(%{"authorization_servers" => [server | _]}), do: server

  defp get_authorization_server(%{"authorization_servers" => server}) when is_binary(server),
    do: server

  defp get_authorization_server(_), do: "https://oauth.notion.com"

  # --- Dynamic Client Registration ---

  @doc "Registers a dynamic OAuth client with the authorization server."
  @spec register_client(map(), String.t()) :: {:ok, map()} | {:error, any()}
  def register_client(discovery_info, redirect_uri) do
    body = %{
      "client_name" => "BetterNotion",
      "redirect_uris" => [redirect_uri],
      "token_endpoint_auth_method" => "none",
      "grant_types" => ["authorization_code"],
      "response_types" => ["code"]
    }

    http_post_json(discovery_info.registration_endpoint, body)
  end

  # --- PKCE ---

  @doc "Generates PKCE code verifier and challenge."
  @spec generate_pkce_params() :: %{
          code_verifier: String.t(),
          code_challenge: String.t(),
          code_challenge_method: String.t()
        }
  def generate_pkce_params do
    code_verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    code_challenge =
      :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

    %{
      code_verifier: code_verifier,
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    }
  end

  @doc "Generates a random state parameter for CSRF protection."
  @spec generate_state() :: String.t()
  def generate_state do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # --- Authorization URL ---

  @doc "Builds the authorization URL the user should visit."
  @spec build_authorization_url(map(), map(), map(), String.t(), String.t()) :: String.t()
  def build_authorization_url(discovery_info, client_info, pkce_params, state, redirect_uri) do
    query_params =
      URI.encode_query(%{
        "client_id" => client_info["client_id"],
        "response_type" => "code",
        "redirect_uri" => redirect_uri,
        "state" => state,
        "code_challenge" => pkce_params.code_challenge,
        "code_challenge_method" => "S256"
      })

    discovery_info.authorization_endpoint <> "?" <> query_params
  end

  # --- Token Exchange ---

  @doc "Exchanges an authorization code for access/refresh tokens."
  @spec exchange_code_for_tokens(map(), map(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, any()}
  def exchange_code_for_tokens(discovery_info, client_info, pkce_params, auth_code, redirect_uri) do
    body = %{
      "grant_type" => "authorization_code",
      "code" => auth_code,
      "client_id" => client_info["client_id"],
      "code_verifier" => pkce_params.code_verifier,
      "redirect_uri" => redirect_uri
    }

    http_post_form(discovery_info.token_endpoint, body)
  end

  # --- Token Refresh ---

  @doc "Refreshes an access token using a refresh token."
  @spec refresh_access_token(map(), String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  def refresh_access_token(discovery_info, client_id, refresh_token) do
    body = %{
      "grant_type" => "refresh_token",
      "client_id" => client_id,
      "refresh_token" => refresh_token
    }

    http_post_form(discovery_info.token_endpoint, body)
  end

  # --- Orchestration ---

  @doc """
  Ensures we have a valid access token. Tries in order:
  1. Return cached valid token
  2. Refresh an expired token

  Never opens a browser: when there is no token and none can be refreshed, it
  returns `{:error, :not_authenticated}`. Starting a fresh authorization is an
  explicit action — see `start_auth_flow/0`, driven by `better-notion login`.

  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  @spec ensure_authenticated() :: {:ok, String.t()} | {:error, any()}
  def ensure_authenticated do
    case BetterNotion.TokenStore.get_access_token() do
      {:ok, token} ->
        {:ok, token}

      {:error, :expired} ->
        attempt_refresh()

      {:error, :not_authenticated} ->
        {:error, :not_authenticated}
    end
  end

  defp attempt_refresh do
    tokens = BetterNotion.TokenStore.get_tokens()

    with %{"refresh_token" => refresh_token, "client_id" => client_id} <- tokens,
         {:ok, discovery_info} <- discover_oauth_configuration(),
         {:ok, new_tokens} <- refresh_access_token(discovery_info, client_id, refresh_token) do
      # Preserve client_id in new tokens
      new_tokens = Map.put(new_tokens, "client_id", client_id)
      BetterNotion.TokenStore.store_tokens(new_tokens)
      {:ok, new_tokens["access_token"]}
    else
      {:error, reason} ->
        Logger.warning("Token refresh failed: #{inspect(reason)}")
        BetterNotion.TokenStore.clear_tokens()
        {:error, :not_authenticated}

      _ ->
        {:error, :not_authenticated}
    end
  end

  @doc """
  Starts an OAuth authorization flow and returns the URL the user must visit.

  Runs discovery, dynamic client registration, and PKCE/state generation, then
  stores the state so the `/oauth/callback` endpoint can complete the token
  exchange once the user finishes authorizing in their browser. Unlike a
  browser-driven flow, this neither opens a browser nor blocks — the caller is
  responsible for presenting the URL (e.g. `better-notion login` prints it).

  Returns `{:ok, authorization_url}` or `{:error, reason}`.
  """
  @spec start_auth_flow(String.t() | nil) :: {:ok, String.t()} | {:error, any()}
  def start_auth_flow(base_url \\ nil) do
    base_url =
      case base_url do
        url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
        _ -> Application.get_env(:better_notion, :base_url, "http://localhost:4000")
      end

    redirect_uri = base_url <> @callback_path

    with {:ok, discovery_info} <- discover_oauth_configuration(),
         {:ok, client_info} <- register_client(discovery_info, redirect_uri) do
      pkce_params = generate_pkce_params()
      state = generate_state()

      # Store state for callback verification
      oauth_state = %{
        pkce: pkce_params,
        client_info: client_info,
        discovery_info: discovery_info,
        redirect_uri: redirect_uri
      }

      BetterNotion.TokenStore.store_oauth_state(state, oauth_state)

      auth_url =
        build_authorization_url(discovery_info, client_info, pkce_params, state, redirect_uri)

      {:ok, auth_url}
    end
  end

  # --- HTTP Helpers (using :httpc) ---

  defp http_get(url) do
    url_charlist = String.to_charlist(url)

    case :httpc.request(:get, {url_charlist, []}, ssl_opts(), []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        Jason.decode(IO.iodata_to_binary(body))

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, {:http_error, status, IO.iodata_to_binary(body)}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp http_post_json(url, body) do
    url_charlist = String.to_charlist(url)
    {:ok, json_body} = Jason.encode(body)
    body_charlist = String.to_charlist(json_body)

    case :httpc.request(
           :post,
           {url_charlist, [], ~c"application/json", body_charlist},
           ssl_opts(),
           []
         ) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..201 ->
        Jason.decode(IO.iodata_to_binary(resp_body))

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:error, {:http_error, status, IO.iodata_to_binary(resp_body)}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp http_post_form(url, body) do
    url_charlist = String.to_charlist(url)
    form_body = URI.encode_query(body) |> String.to_charlist()

    case :httpc.request(
           :post,
           {url_charlist, [], ~c"application/x-www-form-urlencoded", form_body},
           ssl_opts(),
           []
         ) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        Jason.decode(IO.iodata_to_binary(resp_body))

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:error, {:http_error, status, IO.iodata_to_binary(resp_body)}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp ssl_opts do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3
      ]
    ]
  end
end
