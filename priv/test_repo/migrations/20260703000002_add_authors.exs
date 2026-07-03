defmodule AshMultiDatalayer.TestRepo.Migrations.AddAuthors do
  use Ecto.Migration

  def change do
    create table(:mdl_authors, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :name, :text
    end

    alter table(:mdl_posts) do
      add :author_id, :uuid
    end
  end
end
