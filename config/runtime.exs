import Config

config :better_notion, :mcp_port, String.to_integer(System.get_env("PORT") || "4000")
