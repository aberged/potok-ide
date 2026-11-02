defmodule PotokIde.Tags.Tagging do
  @moduledoc """
  One tag on one item. Exactly one of the item columns is set; which one is
  the item's kind (`PotokIde.Tags.kinds/0`).
  """

  use Ecto.Schema

  schema "taggings" do
    belongs_to :tag, PotokIde.Tags.Tag
    belongs_to :added_by, PotokIde.Social.Profile

    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile
    belongs_to :event, PotokIde.Events.Event
    belongs_to :value, PotokIde.Social.Value
    belongs_to :attachment, PotokIde.Social.ValueAttachment

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
