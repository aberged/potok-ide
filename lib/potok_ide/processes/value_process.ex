defmodule PotokIde.Processes.ValueProcess do
  @moduledoc """
  One run of an app's process for one value of its collection: a value has at
  most one instance of each process.

  An instance keeps a copy of the graph it started with (`graph`), so a rule
  saved later changes only the instances that start after it. It stands on
  one element of that graph (`element`) and is woken at `wake_at` when a
  task's deadline or a timer is due. `groups` names the sub-groups it made by
  the element that made them, which is where the process may write besides
  the app's group (`PotokIde.Social.ProcessStep.groups`).

  `started_by` is the author of the value, nil when the value is anonymous,
  so that nobody learns from the process who wrote it. `log` keeps who
  finished which task with which outcome, newest last.
  """

  use Ecto.Schema

  @statuses [:running, :waiting, :done, :failed, :cancelled]

  schema "value_processes" do
    belongs_to :app_process, PotokIde.Social.AppProcess
    belongs_to :value, PotokIde.Social.Value
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

    timestamps(type: :utc_datetime)
  end

  @doc "The states of an instance: running, waiting, done, failed and cancelled."
  def statuses, do: @statuses
end
