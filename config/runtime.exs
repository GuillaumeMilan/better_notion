import Config

port = System.get_env("PORT") || "4000"

config :better_notion, :mcp_port, String.to_integer(port)

config :better_notion, :bind_ip, System.get_env("BIND_IP") || "127.0.0.1"

config :better_notion, :base_url, System.get_env("BETTER_NOTION_URL") || "http://localhost:#{port}"

config :better_notion,
       :token_path,
       System.get_env("BETTER_NOTION_TOKEN_PATH") ||
         Path.join(System.user_home!(), ".better_notion/notion_tokens.json")
