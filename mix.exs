defmodule Still.MixProject do
  use Mix.Project

  def project do
    [
      app: :still,
      version: "0.2.2",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: Six],
      releases: releases()
    ]
  end

  defp releases do
    [
      still: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        cookie: "this-will-be-changed-by-install-sh",
        steps: [:assemble, :tar]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Still.Application, []},
      extra_applications: [:logger, :os_mon, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        six: :test,
        "six.detail": :test,
        "six.html": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support", "credo"]
  defp elixirc_paths(:dev), do: ["lib", "credo"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:argon2_elixir, "~> 4.0"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dns_cluster, "~> 0.2.0"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:erlexec, "~> 2.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:gettext, "~> 1.0"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:jason, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:open_api_spex, "~> 3.22"},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:req, "~> 0.5"},
      {:six, "~> 0.3"},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind still", "esbuild still"],
      "assets.deploy": [
        "tailwind still --minify",
        "esbuild still --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
