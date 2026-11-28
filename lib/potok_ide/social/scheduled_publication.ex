defmodule PotokIde.Social.ScheduledPublication do
  @moduledoc """
  A draft that opens to its readers at a time its editor picked
  (`PotokIde.Social.ScheduledPublications`): whether it turns public, and
  whether it takes all its parent's members then. One per group; gone once
  it is published, cancelled or published by hand.
  """
  use Ecto.Schema

  @failures [:not_permitted, :error]

  schema "scheduled_publications" do
    field :publish_at, :utc_datetime
    field :is_public, :boolean
    field :inherits_members, :boolean
    # Why it was not published at its time: its editor may no longer edit the
    # group (`:not_permitted`), or the save failed (`:error`). It stays a draft.
    field :failure, Ecto.Enum, values: @failures

    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end
end
