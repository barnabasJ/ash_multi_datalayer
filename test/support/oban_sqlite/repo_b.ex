defmodule AshMultiDatalayer.Test.ObanSqlite.SkeletonRepoB do
  @moduledoc """
  A second SQLite repo over a *separate* file, used only by the item-11
  named-instance test to give instance B its own isolated `oban_jobs` table —
  the real two-profile client shape (two files, two Oban instances). The entry
  table lives only in `SkeletonRepo`; a flush running under instance B still
  loads its entry from there.
  """
  use AshSqlite.Repo, otp_app: :ash_multi_datalayer

  def installed_extensions, do: []
end
