defmodule PotokIde.Repo.Migrations.AlterProfilesProfilePictureUrlToText do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      modify :profile_picture_url, :text, from: :string
    end
  end
end
