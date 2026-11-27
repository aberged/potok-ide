defmodule PotokIde.Social.ProfileBlock do
  @moduledoc """
  A profile that blocked another. While either of the two has blocked the
  other, their direct conversation is read-only for both (`Access` gives them
  no permission there) and neither opens a new one
  (`Social.get_or_create_direct_group/2`). It touches nothing else: the two
  still meet in the groups they share, where admins decide. Only the blocker
  sees the block and lifts it (`PotokIde.Social.ProfileBlocks`).
  """
  use Ecto.Schema

  schema "profile_blocks" do
    belongs_to :blocker, PotokIde.Social.Profile
    belongs_to :blocked, PotokIde.Social.Profile

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
