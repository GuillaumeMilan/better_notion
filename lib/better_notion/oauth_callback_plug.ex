defmodule BetterNotion.OAuthCallbackPlug do
  @moduledoc """
  Plug.Router that handles the OAuth callback from Notion's authorization server.

  Handles `GET /oauth/callback?code=...&state=...` by verifying the state parameter,
  exchanging the authorization code for tokens, and storing them.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/oauth/callback" do
    conn = Plug.Conn.fetch_query_params(conn)
    params = conn.query_params

    case params do
      %{"error" => error} ->
        error_desc = Map.get(params, "error_description", "Unknown error")
        send_html(conn, 400, error_page(error, error_desc))

      %{"code" => code, "state" => state} ->
        handle_auth_callback(conn, code, state)

      _ ->
        send_html(conn, 400, error_page("invalid_request", "Missing code or state parameter"))
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp handle_auth_callback(conn, code, state) do
    alias BetterNotion.{TokenStore, NotionAuth}

    case TokenStore.get_oauth_state(state) do
      {:ok, oauth_state} ->
        %{
          pkce: pkce_params,
          client_info: client_info,
          discovery_info: discovery_info,
          redirect_uri: redirect_uri
        } = oauth_state

        case NotionAuth.exchange_code_for_tokens(
               discovery_info,
               client_info,
               pkce_params,
               code,
               redirect_uri
             ) do
          {:ok, token_data} ->
            # Store client_id alongside tokens for future refresh
            token_data = Map.put(token_data, "client_id", client_info["client_id"])
            TokenStore.store_tokens(token_data)
            TokenStore.delete_oauth_state(state)

            # Notify the waiting process if any
            if pid = oauth_state[:waiting_pid] do
              send(pid, {:oauth_complete, {:ok, token_data["access_token"]}})
            end

            send_html(conn, 200, success_page())

          {:error, reason} ->
            notify_error(oauth_state, reason)
            send_html(conn, 500, error_page("token_exchange_failed", inspect(reason)))
        end

      {:error, :state_not_found} ->
        send_html(conn, 400, error_page("invalid_state", "OAuth state not found. Please try again."))

      {:error, :state_expired} ->
        send_html(conn, 400, error_page("state_expired", "OAuth session expired. Please try again."))
    end
  end

  defp notify_error(oauth_state, reason) do
    if pid = oauth_state[:waiting_pid] do
      send(pid, {:oauth_complete, {:error, reason}})
    end
  end

  defp send_html(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  defp success_page do
    """
    <!DOCTYPE html>
    <html>
    <head><title>Authorization Successful</title>
    <style>
      body { font-family: -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
      .card { background: white; padding: 2rem; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); text-align: center; max-width: 400px; }
      h1 { color: #2ecc71; }
    </style>
    </head>
    <body>
      <div class="card">
        <h1>Authorization Successful</h1>
        <p>BetterNotion has been connected to your Notion workspace.</p>
        <p>You can close this window and return to your terminal.</p>
      </div>
    </body>
    </html>
    """
  end

  defp error_page(error, description) do
    """
    <!DOCTYPE html>
    <html>
    <head><title>Authorization Failed</title>
    <style>
      body { font-family: -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
      .card { background: white; padding: 2rem; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); text-align: center; max-width: 400px; }
      h1 { color: #e74c3c; }
      code { background: #f8f8f8; padding: 2px 6px; border-radius: 3px; }
    </style>
    </head>
    <body>
      <div class="card">
        <h1>Authorization Failed</h1>
        <p><strong>Error:</strong> <code>#{Plug.HTML.html_escape(error)}</code></p>
        <p>#{Plug.HTML.html_escape(description)}</p>
        <p>Please close this window and try again.</p>
      </div>
    </body>
    </html>
    """
  end
end
