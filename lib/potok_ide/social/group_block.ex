defmodule PotokIde.Social.GroupBlock do
  @moduledoc """
  A profile that may not write in an open chat of a group, nor react there, as
  long as it is not a member. Membership comes first: a member answers to their
  roles. `Social.block_from_group/3` is the way in.
  """

  use Ecto.Schema

  schema "group_blocks" do
    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile
    # Nil once that profile is gone: the block stays.
    belongs_to :blocked_by, PotokIde.Social.Profile

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
