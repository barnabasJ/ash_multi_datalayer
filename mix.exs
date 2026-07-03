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
      # Pinned to hex-cache-available versions (sandbox has no hex.pm access);
      # matches ash_remote's lock so both projects share identical deps.
      {:crux, "0.1.3", override: true},
      # No :only restriction — ash 3.29+ depends on stream_data in all envs.
      {:stream_data, "~> 1.0"},
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
