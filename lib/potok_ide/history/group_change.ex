defmodule PotokIde.History.GroupChange do
  @moduledoc """
  One change in a group's history (`PotokIde.History`), written by Postgres in
  the transaction that made it.

  `subject_type` and `subject_id` say what changed and `op` how. `fields` are
  the names of what changed, `before` their old values: nil where only the
  fact is kept (messages, reactions, notices), and once someone emptied it
  (`purged_at`, `purged_by`). `actor` is who did it, nil when nobody did (a
  deadline, a decision) or when it is not known; `creator` is whose the thing
  is. `cause` says why: a poll, a step of a process, a version put back.

  `keys_before` and `keys_after` are the roles that saw the thing on each side
  of the change, nil for what every member sees. `op_id` is shared by the
  changes of one act, such as deleting a whole collection, of which one is
  `listed` and says how many they were (`cause["count"]`). `last_at` is when
  the last change of a merged burst was.

  `subject_type` is a plain string and not an enum: a new kind is written by
  the migration before the code that knows it runs.
  """

  use Ecto.Schema

  schema "group_changes" do
    field :subject_type, :string
    field :subject_id, :integer
    field :op, Ecto.Enum, values: [:created, :changed, :deleted]
    field :fields, {:array, :string}, default: []
    # A description may be 300 KB, so lists leave it out.
    field :before, :map, load_in_query: false
    field :alt_description_id, :integer
    field :collection, :string
    field :anonymous, :boolean, default: false
    field :keys_before, {:array, :string}
    field :keys_after, {:array, :string}
    field :cause, :map
    field :op_id, :integer
    field :listed, :boolean, default: true
    field :at, :utc_datetime_usec
    field :last_at, :utc_datetime_usec
    field :purged_at, :utc_datetime
    # Of a change of a poll's end: whether it ended, or opened again (`Feed`).
    field :closing?, :boolean, virtual: true
    # Of a sub-group moved to another parent: that one's id, as `%{"to" => id}`
    # where it left and `%{"from" => id}` where it came (`Feed`).
    field :moved, :map, virtual: true

    belongs_to :group, PotokIde.Social.Group
    belongs_to :actor, PotokIde.Social.Profile
    belongs_to :creator, PotokIde.Social.Profile
    belongs_to :purged_by, PotokIde.Social.Profile
  end
end
