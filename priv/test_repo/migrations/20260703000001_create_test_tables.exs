defmodule AshMultiDatalayer.TestRepo.Migrations.CreateTestTables do
  use Ecto.Migration

  def change do
    create table(:mdl_posts, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :name, :text
      add :age, :bigint
      add :score, :decimal
      add :published_at, :date
    end
  end
end
