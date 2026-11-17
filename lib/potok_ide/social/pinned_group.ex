defmodule PotokIde.Social.PinnedGroup do
  @moduledoc """
  A group a profile keeps at the top of its column of groups
  (`PotokIde.Social.PinnedGroups`). Only that profile sees it.
  """

  use Ecto.Schema

  schema "pinned_groups" do
    belongs_to :profile, PotokIde.Social.Profile
    belongs_to :group, PotokIde.Social.Group

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
