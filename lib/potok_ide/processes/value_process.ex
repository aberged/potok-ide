defmodule PotokIde.Processes.ValueProcess do
  @moduledoc """
  One run of a process. Its subject is a value of a collection (or a chat
  message, `value`), a new sub-group (`subject_group`), or nothing, for a
  scheduled or a hand-started run (`PotokIde.Processes.Triggers`); a value or
  a sub-group has at most one instance of each process that its trigger
  started. `data` keeps the fields its texts and conditions read when the
  subject is no value of a collection, whose own data they read otherwise.

  A run another process started, by a call or a signal, is one level deeper
  than that one (`depth`), shares its subject and keeps in `data` the fields
  it was given. A caller that waits for the run it called holds it in
  `awaiting`. What a wait brought back (a called run's end, a signal, a
  person's decision) stays in `results` under the element that waited, for
  the texts and conditions that follow, as `{{element.field}}`. The variables
  its process declares are kept in `vars`, each run its own.

  An instance keeps a copy of the graph it started with (`graph`), so a rule
  saved later changes only the instances that start after it. It stands on
  one element of that graph (`element`) and is woken at `wake_at` when a
  task's deadline or a timer is due. `groups` names the sub-groups it made by
  the element that made them, which is where the process may write besides
  the app's group (`PotokIde.Social.ProcessStep.groups`).

  `started_by` is the author of the value, nil when the value is anonymous,
  so that nobody learns from the process who wrote it. `log` keeps who
  finished which task with which outcome, and who filled in which form,
  newest last.

  While it waits on a step a person finishes it keeps whom it asks: the
  people of a role (`asks_role`), or one person (`asks_profile`), for a form
  that whoever started it fills in. Both are written on every entry into a
  wait, empty for one no person ends, and say nothing in any other state.
  """

  use Ecto.Schema

  @statuses [:running, :waiting, :done, :failed, :cancelled]

  schema "value_processes" do
    belongs_to :app_process, PotokIde.Social.AppProcess
    belongs_to :value, PotokIde.Social.Value
    belongs_to :subject_group, PotokIde.Social.Group
    field :data, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :running
    field :element, :string
    field :graph, :map
    field :groups, :map, default: %{}
    belongs_to :started_by, PotokIde.Social.Profile
    # Who set off the step it is on (`ProcessStep.triggered_by`): the value's
    # author, whoever finished a task, nil after a timer or for an anonymous
    # value. Kept, so a step taken up again after a crash knows it still.
    belongs_to :triggered_by, PotokIde.Social.Profile
    field :wake_at, :utc_datetime
    field :steps, :integer, default: 0
    # `%{"element" => ..., "reason" => ...}` once it has failed.
    field :error, :map
    field :log, {:array, :map}, default: []
    belongs_to :awaiting, __MODULE__
    field :depth, :integer, default: 0
    field :results, :map, default: %{}
    # What its variables hold, by name, as plain JSON (`Processes.Types`).
    field :vars, :map, default: %{}
    # Whom the wait it stands on asks, if it asks anyone.
    field :asks_role, :string
    belongs_to :asks_profile, PotokIde.Social.Profile
    # The signal it waits for at a step that hears the groups above and
    # below too, while it waits there (`Processes.Engine`), for finding it.
    field :related_signal, :string

    timestamps(type: :utc_datetime)
  end

  @doc "The states of an instance: running, waiting, done, failed and cancelled."
  def statuses, do: @statuses
end
