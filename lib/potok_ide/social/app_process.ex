defmodule PotokIde.Social.AppProcess do
  @moduledoc """
  The process of one collection of one app: the profile that signs what it
  does (`Profile.kind` `:process`), and its owner, the editor who last brought
  it to life. `PotokIde.Social.AppProcesses` is the way in; nothing is cast.

  An inactive one waits for its rule to come back, with the same profile, so
  what the process wrote keeps one author.

  `collection` is nil for a drawn process that starts on something else
  than a value of a collection (`trigger`).

  A drawn one (`drawn`) is drawn by an editor in Potok
  (`PotokIde.Social.DrawnProcesses`) rather than written by the app: its
  graph and where its elements stand on a wide screen live here, and the
  app's own rules never touch it. It starts inactive, as a drawing.
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
    field :drawn, :boolean, default: false
    # A drawn process's normalized graph (`Processes.Graph`); nil for an app's.
    field :graph, :map
    # %{"nodes" => %{id => [x, y]}}: a drawing's positions, set on a wide screen.
    field :layout, :map, default: %{}
    field :lock_version, :integer, default: 1
    # What sets an instance going (`PotokIde.Processes.Triggers`): a new value
    # of `collection` ("value", always for an app's own process), a chat
    # message, a new sub-group, a schedule, or someone by hand.
    field :trigger, :string, default: "value"
    field :trigger_config, :map, default: %{}
    # The next start of a scheduled process, nil for every other trigger.
    field :next_run_at, :utc_datetime
    # The entity a drawn process takes when it starts, where its trigger lets
    # it take one (`Processes.Triggers.typed?/1`); nil for one that takes none.
    belongs_to :entry_entity, PotokIde.Processes.GroupEntity

    timestamps(type: :utc_datetime)
  end
end
