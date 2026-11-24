defmodule PotokIde.Social.GroupAccountInvitation do
  @moduledoc """
  An invitation by email into a group, addressed to an account rather than
  a profile (`PotokIde.Social.EmailInvitations`): the person picks which of
  their profiles accepts it, or makes one, and the inviter learns that
  profile only then. Until then the inviter sees the address they typed
  (`email`). Each inviter keeps an invitation of their own; it lapses like a
  group invitation (`GroupInvitation.valid_days/0`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_account_invitations" do
    belongs_to :group, PotokIde.Social.Group
    belongs_to :inviter, PotokIde.Social.Profile
    belongs_to :account, PotokIde.Accounts.Account
    field :email, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:group_id, :inviter_id, :account_id, :email])
    |> validate_required([:group_id, :inviter_id, :account_id])
    |> unique_constraint([:group_id, :account_id, :inviter_id],
      name: :group_account_invitations_group_id_account_id_inviter_id_index
    )
  end
end
