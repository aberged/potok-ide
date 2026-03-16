defmodule PotokIde.Social.GroupInvitation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_invitations" do
    field :accepted_at, :utc_datetime

    belongs_to :group, PotokIde.Social.Group
    belongs_to :inviter, PotokIde.Social.Profile
    belongs_to :invitee, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:group_id, :inviter_id, :invitee_id, :accepted_at])
    |> validate_required([:group_id, :inviter_id, :invitee_id])
    |> unique_constraint([:group_id, :invitee_id],
      name: :group_invitations_group_id_invitee_id_pending_index
    )
  end

  def accept_changeset(invitation) do
    change(invitation, accepted_at: DateTime.utc_now(:second))
  end
end
