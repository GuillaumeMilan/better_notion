import Config

config :better_notion, :mcp_port, String.to_integer(System.get_env("PORT") || "4000")

config :better_notion,
  :token_path,
  System.get_env("BETTER_NOTION_TOKEN_PATH") ||
    Path.join(System.user_home!(), ".better_notion/notion_tokens.json")
