defmodule PotokIde.Social.GroupInvitation do
  @moduledoc """
  An invitation from a profile to a profile to join a group. One not
  accepted within `valid_days/0` lapses: it can no longer be accepted, it is
  not shown or counted, the same profile can be invited anew, and the hourly
  sweep deletes it (`PotokIde.Social.delete_expired_invitations/0`). An
  accepted one stays, as the record of who brought whom in.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @valid_days 30

  @doc "How many days an invitation waits to be accepted."
  def valid_days, do: @valid_days

  @doc "Invitations sent at or before this moment have lapsed, unless accepted."
  def cutoff(now \\ DateTime.utc_now(:second)), do: DateTime.add(now, -@valid_days, :day)

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

  @doc """
  Accepts `invitation` for the profile `joining_id` that comes in by it: its
  invitee, or another unique profile of the same account
  (`PotokIde.Social.accept_group_invitation_as/3`), which the invitation then
  names, as the record of who came in.
  """
  def accept_changeset(invitation, joining_id \\ nil) do
    change(invitation,
      invitee_id: joining_id || invitation.invitee_id,
      accepted_at: DateTime.utc_now(:second)
    )
  end

  @doc "Whether `invitation` waits no longer: not accepted and past its days."
  def expired?(invitation, now \\ DateTime.utc_now(:second))

  def expired?(%__MODULE__{accepted_at: nil, inserted_at: %DateTime{} = at}, now),
    do: DateTime.compare(at, cutoff(now)) != :gt

  def expired?(%__MODULE__{}, _now), do: false

  @doc "When `invitation` lapses."
  def expires_at(%__MODULE__{inserted_at: %DateTime{} = at}),
    do: DateTime.add(at, @valid_days, :day)
end
