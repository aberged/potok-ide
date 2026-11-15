defmodule PotokIde.Social.AppProcess do
  @moduledoc """
  The process of one collection of one app: the profile that signs what it
  does (`Profile.kind` `:process`), and its owner, the editor who last brought
  it to life. `PotokIde.Social.AppProcesses` is the way in; nothing is cast.

  An inactive one waits for its rule to come back, with the same profile, so
  what the process wrote keeps one author.
  """

  use Ecto.Schema

  schema "app_processes" do
    belongs_to :profile, PotokIde.Social.Profile
    belongs_to :group, PotokIde.Social.Group
    # Nil for the app of the group's default description.
    belongs_to :alt_description, PotokIde.Social.GroupAltDescription
    field :collection, :string
    # The rule's `process.name`, as last saved; shown instead of the username.
    field :name, :string
    # Nil once that profile is gone: the next editor to save the rule owns it.
    belongs_to :owner_profile, PotokIde.Social.Profile
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end
end
