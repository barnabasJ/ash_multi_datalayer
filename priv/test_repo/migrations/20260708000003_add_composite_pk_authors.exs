defmodule AshMultiDatalayer.TestRepo.Migrations.AddCompositePkAuthors do
  use Ecto.Migration

  def change do
    create table(:mdl_composite_pk_authors, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :tenant, :text, null: false, primary_key: true
      add :name, :text
    end
  end
end
