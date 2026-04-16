defmodule PotokIde.Repo.Migrations.AddGroupAccountInvitations do
  use Ecto.Migration

  def change do
    create table(:group_account_invitations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :inviter_id, references(:profiles, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_account_invitations, [:group_id])
    create index(:group_account_invitations, [:inviter_id])
    create index(:group_account_invitations, [:account_id])

    create unique_index(:group_account_invitations, [:group_id, :account_id],
             name: :group_account_invitations_group_id_account_id_index
           )
  end
end
