defmodule PotokIde.Repo.Migrations.AddIsRootPublicToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :is_root_public, :boolean, null: false, default: false
    end

    create constraint(:groups, :groups_root_public_requires_public_check,
             check: "NOT (is_root_public AND NOT is_public)"
           )
  end
end
