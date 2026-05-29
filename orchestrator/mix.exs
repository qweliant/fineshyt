defmodule Orchestrator.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchestrator,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  # Release configuration.
  #
  #   :prune_user_data — strips priv/static/uploads from the artifact
  #     (those JPEGs reach several GB; STATIC_UPLOADS_DIR redirects
  #     reads/writes at runtime, so the bundled copies are dead weight).
  #
  # Burrito wrap step is *opt-in* via `BURRITO=1` env var. Reason:
  # Burrito 1.5.0 pins Zig 0.15.2, which has a known libSystem
  # weak-linking failure on macOS 26 (Tahoe) — see upstream issue
  # https://github.com/burrito-elixir/burrito/issues/221. Until that
  # ships a fix (or we move cross-platform builds to GitHub Actions
  # runners on macOS 14/15 where Zig 0.15 still works), plain
  # `mix release` is the local-build path and Burrito wrapping is
  # gated. The dep stays in mix.exs as a marker for future re-enable.
  defp releases do
    base_steps = [:assemble, &prune_user_data/1]

    steps =
      if System.get_env("BURRITO") in ~w(1 true) do
        base_steps ++ [&Burrito.wrap/1]
      else
        base_steps
      end

    [
      orchestrator: [
        steps: steps,
        burrito: [
          targets: [
            macos_silicon: [os: :darwin, cpu: :aarch64],
            macos_intel: [os: :darwin, cpu: :x86_64],
            linux: [os: :linux, cpu: :x86_64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp prune_user_data(%Mix.Release{path: release_path, version: vsn} = release) do
    uploads_dir =
      Path.join([release_path, "lib", "orchestrator-#{vsn}", "priv", "static", "uploads"])

    if File.exists?(uploads_dir) do
      File.rm_rf!(uploads_dir)
    end

    release
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Orchestrator.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.17"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:oban, "~> 2.20.3"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # Burrito wraps the Mix release into a self-extracting Zig binary
      # with embedded ERTS so we can build Windows / Linux / macOS
      # artifacts cross-platform from a single host. Phase 0 of the
      # native packaging plan. `runtime: false` because Burrito is a
      # build-time tool — its modules don't ship inside the release.
      {:burrito, "~> 1.5"}
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
      "assets.build": ["compile", "tailwind orchestrator", "esbuild orchestrator"],
      "assets.deploy": [
        "tailwind orchestrator --minify",
        "esbuild orchestrator --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
