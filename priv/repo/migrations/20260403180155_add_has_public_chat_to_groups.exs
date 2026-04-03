defmodule PotokIde.Repo.Migrations.AddHasPublicChatToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add :has_public_chat, :boolean, null: false, default: false
    end
  end
end
