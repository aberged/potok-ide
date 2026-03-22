defmodule PotokIde.Social.ProfileInvitation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "profile_invitations" do
    field :accepted_at, :utc_datetime

    belongs_to :profile, PotokIde.Social.Profile
    belongs_to :inviter, PotokIde.Social.Profile
    belongs_to :invitee, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:profile_id, :inviter_id, :invitee_id, :accepted_at])
    |> validate_required([:profile_id, :inviter_id, :invitee_id])
    |> unique_constraint([:profile_id, :invitee_id],
      name: :profile_invitations_profile_id_invitee_id_pending_index
    )
  end

  def accept_changeset(invitation) do
    change(invitation, accepted_at: DateTime.utc_now(:second))
  end
end
