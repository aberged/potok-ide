defmodule PotokIde.Repo.Migrations.AddEmailToGroupAccountInvitations do
  use Ecto.Migration

  # An invitation by email now goes to the account, which picks the profile
  # that accepts it (`PotokIde.Social.EmailInvitations`). Until then the
  # inviter sees the address typed in, kept here; each inviter keeps an
  # invitation of their own, so the key takes the inviter too. Those sent
  # before have none: the account's address may have changed since, and the
  # inviter is not to learn the new one.
  def up do
    alter table(:group_account_invitations) do
      add :email, :string
    end

    drop index(:group_account_invitations, [:group_id, :account_id],
           name: :group_account_invitations_group_id_account_id_index
         )

    create unique_index(:group_account_invitations, [:group_id, :account_id, :inviter_id],
             name: :group_account_invitations_group_id_account_id_inviter_id_index
           )
  end

  def down do
    drop index(:group_account_invitations, [:group_id, :account_id, :inviter_id],
           name: :group_account_invitations_group_id_account_id_inviter_id_index
         )

    execute """
    DELETE FROM group_account_invitations i
    USING group_account_invitations other
    WHERE other.group_id = i.group_id AND other.account_id = i.account_id AND other.id < i.id
    """

    create unique_index(:group_account_invitations, [:group_id, :account_id],
             name: :group_account_invitations_group_id_account_id_index
           )

    alter table(:group_account_invitations) do
      remove :email
    end
  end
end
