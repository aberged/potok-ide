defmodule PotokIde.Processes.RunEvent do
  @moduledoc """
  One thing a run of a process did (`PotokIde.Processes.RunEvents`), written by
  Postgres as the run's row moves:

  - `started`, and by whom, nil for a schedule and for an anonymous value;
  - `passed`: a step it went through, with what it made of the variables;
  - `waits`: it stopped for a person, a time, a poll, a signal or a call;
  - `answered`: a person decided or filled in a form (`actor`, `outcome`);
  - `woke`: what it waited for came, or its deadline did;
  - `failed` (`outcome` is why), `retried`, `cancelled`, `done`.

  `label` (nil for a step with no name) and `type`, what the step does, are as
  it was drawn then. `vars` holds
  `[before, after]` of each variable the step changed, for 30 days. A loop's
  steps past the first of a run add up (`count`, until `last_at`).

  A run goes with its value or its process, and its trace stays with the
  group, so `run_id` and `app_process_id` have no keys.
  """

  use Ecto.Schema

  schema "process_run_events" do
    field :app_process_id, :integer
    field :run_id, :integer
    field :kind, :string
    field :element, :string
    field :label, :string
    field :type, :string
    field :outcome, :string
    field :vars, :map
    field :count, :integer, default: 1
    field :at, :utc_datetime_usec
    field :last_at, :utc_datetime_usec

    belongs_to :group, PotokIde.Social.Group
    belongs_to :actor, PotokIde.Social.Profile
  end
end
