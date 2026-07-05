defmodule AshMultiDatalayer.Test.ObanSqlite.SkeletonRepo do
  @moduledoc """
  Phase 2 walking-skeleton repo: `AshSqlite.Repo` (ecto_sqlite3 adapter) over one
  SQLite file that carries the resource table, the outbox-style entry table, and
  the Oban Lite `oban_jobs` table. Started by the skeleton test's `setup_all`
  against a fresh temp file; not in `ecto_repos`.
  """
  use AshSqlite.Repo, otp_app: :ash_multi_datalayer

  def installed_extensions, do: []
end
