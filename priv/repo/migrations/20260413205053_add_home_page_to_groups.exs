defmodule PotokIde.Repo.Migrations.AddHomePageToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :home_page, :string, null: false, default: "description"
    end

    create constraint(:groups, :groups_home_page_check,
             check: "home_page IN ('chat', 'description', 'subgroups')"
           )
  end
end
