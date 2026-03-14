defmodule BetterNotion.MixProject do
  use Mix.Project

  def project do
    [
      app: :better_notion,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {BetterNotion.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:hackney, "~> 1.17"},
      {:jason, "~> 1.4"},
      {:mcp_server, "~> 0.8.0"},
      {:bandit, "~> 1.0"}
    ]
  end
end
