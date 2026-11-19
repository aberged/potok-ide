defmodule PotokIde.Social.AppProfileEntry do
  @moduledoc """
  One key of an app's personal memory for one profile
  (`PotokIde.Social.AppProfileStore`): what an app, or a site in its frame,
  keeps for that person alone, such as how far they read. Nobody else reads
  it, not even the app's editors.
  """
  use Ecto.Schema

  schema "app_profile_entries" do
    belongs_to :group, PotokIde.Social.Group
    # The alternative description whose app it is; nil for the default one.
    belongs_to :alt_description, PotokIde.Social.GroupAltDescription
    belongs_to :profile, PotokIde.Social.Profile

    field :key, :string
    # `%{"v" => value}`: a value is anything JSON holds, a map only wraps it.
    # Read it with `PotokIde.Social.AppProfileStore`, which unwraps it.
    field :value, :map

    timestamps(type: :utc_datetime)
  end
end
