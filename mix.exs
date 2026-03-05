defmodule Sentinel.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/fun-fx/sentinel"

  def project do
    [
      app: :sentinel,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      test_coverage: [summary: [threshold: 80]],
      name: "Sentinel",
      description: "In-process autonomous dev agent for Elixir. Captures errors, creates tickets, picks up board work, and runs Codex to investigate and fix.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      mod: {Sentinel.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:codex_app_server, "~> 0.1"},
      {:linear_client, "~> 0.1"},
      {:jason, "~> 1.4"},
      {:circular_buffer, "~> 0.4 or ~> 1.0"},
      {:req, "~> 0.5"},
      {:plug, "~> 1.15", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [lint: ["credo --strict"]]
  end

  defp package do
    [
      name: "sentinel_ai",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [main: "readme", extras: ["README.md"], source_ref: "v#{@version}"]
  end
end
