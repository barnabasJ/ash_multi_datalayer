defmodule AshMultiDatalayer.TestRepo.Migrations.AddMtAttrPosts do
  use Ecto.Migration

  def change do
    create table(:mdl_mt_attr_posts, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :org_id, :text
      add :organization_id, :text
      add :title, :text
    end
  end
end
