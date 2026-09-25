defmodule AshMultiDatalayer.MixHelpers do
  @moduledoc """
  Domain resolution shared by `mix ash_multi_datalayer.generate_migrations`
  and `mix ash_multi_datalayer.generate_sqlite_migrations`.

  Deliberately not `AshPostgres.Mix.Helpers`/`AshSqlite.Mix.Helpers`, and not
  `Ash.Mix.Tasks.Helpers` either: the former two would make an optional
  dependency mandatory just to resolve `--domains`/`config :app, ash_domains`,
  and the latter's own `OptionParser.parse!(strict: [domains: ...])` rejects
  every other flag callers like `mix ash.codegen` forward (`--name`,
  `--quiet`, etc.). This mirrors their domain-resolution logic exactly, minus
  both problems.
  """

  @doc """
  Resolves the domain list from `opts[:domains]` (already parsed by the
  caller) or each app's configured `:ash_domains`, ensuring every domain (and
  its resources) is compiled. `args` is the original, full argv — forwarded
  as-is to `app.config`/`loadpaths`/`compile` so unrelated flags the caller
  parsed for itself don't need to be stripped first.
  """
  @spec domains!(Keyword.t(), [String.t()]) :: [module()]
  def domains!(opts, args) do
    apps =
      if apps_paths = Mix.Project.apps_paths() do
        apps_paths |> Map.keys() |> Enum.sort()
      else
        [Mix.Project.config()[:app]]
      end

    domains =
      if opts[:domains] && opts[:domains] != "" do
        opts[:domains]
        |> String.split(",")
        |> Enum.flat_map(fn
          "" -> []
          domain -> [Module.concat([domain])]
        end)
      else
        Enum.flat_map(apps, &Application.get_env(&1, :ash_domains, []))
      end

    Enum.map(domains, &ensure_compiled(&1, args))
  end

  defp ensure_compiled(domain, args) do
    if Code.ensure_loaded?(Mix.Tasks.App.Config) do
      Mix.Task.run("app.config", args)
    else
      Mix.Task.run("loadpaths", args)
      "--no-compile" not in args && Mix.Task.run("compile", args)
    end

    case Code.ensure_compiled(domain) do
      {:module, _} ->
        domain
        |> Ash.Domain.Info.resources()
        |> Enum.each(&Code.ensure_compiled/1)

        domain

      {:error, error} ->
        Mix.raise("Could not load #{inspect(domain)}, error: #{inspect(error)}. ")
    end
  end
end
