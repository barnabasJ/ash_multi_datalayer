defmodule AshMultiDatalayer.TestRepo.Migrations.AddMtAttrPostsUpsertCondition do
  use Ecto.Migration

  def change do
    alter table(:mdl_mt_attr_posts) do
      add :version, :integer, default: 0
    end

    create unique_index(:mdl_mt_attr_posts, [:org_id, :title])
  end
end
