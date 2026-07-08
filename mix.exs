defmodule AshMultiDatalayer.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/barnabasJ/ash_multi_datalayer"

  def project do
    [
      app: :ash_multi_datalayer,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs()
    ]
  end

  defp description do
    "An Ash.DataLayer that composes multiple data stores (e.g. an ETS " <>
      "read-through cache in front of Postgres) behind a single Ash resource, " <>
      "with a coverage ledger, row-aware invalidation, a kill-switch, and " <>
      "orchestration strategies for caching, tiering, and offline-first sync."
  end

  # P5: explicit `files:` — Hex's default file set would otherwise ship
  # `priv/test_repo/migrations/*` (test-only fixtures, not a real consumer's
  # migration source) alongside the real library.
  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE docs/guides
                 docs/technical docs/runbooks docs/design)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "docs/guides/ash-multi-datalayer.md",
        "docs/technical/ash-multi-datalayer.md",
        "docs/runbooks/ash-multi-datalayer.md"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.29"},
      {:spark, "~> 2.0"},
      # Optional: only needed when AshPostgres.DataLayer is used as a layer.
      {:ash_postgres, "~> 2.0", optional: true},
      {:ecto_sql, "~> 3.10", optional: true},
      {:postgrex, ">= 0.0.0", optional: true},
      # LocalOutbox strategy stack — optional, required only by
      # `AshMultiDatalayer.Orchestrator.LocalOutbox` and its tests. Exact-pinned
      # like `crux`. NB: `ecto_sqlite3` is pinned to 0.24.1, NOT the plan's
      # original ≤0.22.0 offline-cache figure: 0.22.0 caps `decimal` at `< 3.0`
      # (the CVE-affected range), which cannot coexist with ash 3.29 → ecto 3.14
      # → `decimal ~> 3.0`. 0.24.1 requires `decimal ~> 3.0` and resolves
      # cleanly. See the plan's Phase 2 Addendum.
      {:oban, "2.23.0", optional: true},
      {:ash_oban, "0.8.10", optional: true},
      {:ash_sqlite, "0.2.17", optional: true},
      {:ecto_sqlite3, "0.24.1", optional: true},
      # Powers the Phase 3 install/gen.outbox generators. Optional — only the
      # mix tasks need it; runtime code never does.
      {:igniter, "0.8.2", optional: true},
      # P5: was `"0.1.3", override: true` — `override: true` makes the
      # package unbuildable via `mix hex.build` (Hex rejects an override
      # dependency in a publishable package), and the exact pin
      # over-constrains consumers beyond what ash itself requires
      # transitively (`>= 0.1.2 and < 1.0.0-0`). `~> 0.1` is satisfied by
      # the already-locked 0.1.3 (no re-resolution needed) while leaving
      # consumers free to pick any compatible 0.1.x.
      {:crux, "~> 0.1"},
      # No :only restriction — ash 3.29+ depends on stream_data in all envs.
      {:stream_data, "~> 1.0"},
      # Not `:only [:dev, :test]` — igniter (via ex_ast) requires sourceror in
      # all envs. Harmless: it is a compile-time AST tool, unused at runtime.
      {:sourceror, "~> 1.7"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
