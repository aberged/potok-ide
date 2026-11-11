defmodule PotokIde.Notices.GroupFollow do
  @moduledoc """
  A profile follows a group, to receive the notices it sends. Anyone who may
  see the group may follow it, member or not (`PotokIde.Notices.can_follow?/3`);
  the row stays when that changes, and a notice reaches only those who see the
  group when it is sent.

  `push` says whether the follower's devices get a push for this group's
  notices; the profile's own `notice_push` turns them all off.
  """

  use Ecto.Schema

  schema "group_follows" do
    field :push, :boolean, default: true

    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end
end
