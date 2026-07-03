defmodule AshMultiDatalayer.TestRepo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :ash_multi_datalayer

  def installed_extensions do
    ["ash-functions", "uuid-ossp"]
  end

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
