defmodule AshMultiDatalayer.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ash_multi_datalayer,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
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
      # Pinned to hex-cache-available versions (sandbox has no hex.pm access);
      # matches ash_remote's lock so both projects share identical deps.
      {:crux, "0.1.3", override: true},
      # No :only restriction — ash 3.29+ depends on stream_data in all envs.
      {:stream_data, "~> 1.0"},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
