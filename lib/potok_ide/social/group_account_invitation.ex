defmodule PotokIde.Social.GroupAccountInvitation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_account_invitations" do
    belongs_to :group, PotokIde.Social.Group
    belongs_to :inviter, PotokIde.Social.Profile
    belongs_to :account, PotokIde.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:group_id, :inviter_id, :account_id])
    |> validate_required([:group_id, :inviter_id, :account_id])
    |> unique_constraint([:group_id, :account_id],
      name: :group_account_invitations_group_id_account_id_index
    )
  end
end
