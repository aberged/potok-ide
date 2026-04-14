defmodule PotokIde.Repo.Migrations.AlterGroupsGroupPictureUrlToText do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      modify :group_picture_url, :text, from: :string
    end
  end
end
