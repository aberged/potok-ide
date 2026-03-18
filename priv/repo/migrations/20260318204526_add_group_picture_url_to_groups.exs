defmodule PotokIde.Repo.Migrations.AddGroupPictureUrlToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :group_picture_url, :string
    end
  end
end
