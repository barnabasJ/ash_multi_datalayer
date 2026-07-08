defmodule AshMultiDatalayer.TestRepo.Migrations.AddSourceOverrideAuthors do
  use Ecto.Migration

  def change do
    create table(:mdl_source_override_authors, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :name, :text
    end
  end
end
