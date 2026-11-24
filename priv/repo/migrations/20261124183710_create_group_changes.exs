defmodule PotokIde.Repo.Migrations.CreateGroupChanges do
  use Ecto.Migration

  # The history of a group (`PotokIde.History`): one row for each change of
  # what the group keeps, written by the triggers of the next migration, in
  # the transaction that makes the change. It starts empty, and goes with the
  # group. `before` holds the old values of what changed, and nothing where
  # only the fact is kept (messages, reactions, notices). Nobody's name is in
  # it, only the profile's id.
  def change do
    create table(:group_changes) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :subject_type, :string, null: false
      add :subject_id, :bigint, null: false
      add :op, :string, null: false
      add :fields, {:array, :text}, null: false, default: []
      add :before, :map
      add :actor_id, references(:profiles, on_delete: :nilify_all)
      add :creator_id, references(:profiles, on_delete: :nilify_all)

      # The description a record or a process is filed under. No key: the
      # history of a deleted description's app outlives it.
      add :alt_description_id, :bigint
      add :collection, :string
      add :anonymous, :boolean, null: false, default: false

      # The roles that saw the thing before and after the change; nil for
      # what every member sees.
      add :keys_before, {:array, :text}
      add :keys_after, {:array, :text}
      add :cause, :map

      # One act may delete a collection of 100,000 records. Each keeps a row,
      # for what it was, and one of them stands for all in the history.
      add :op_id, :bigint
      add :listed, :boolean, null: false, default: true
      add :at, :utc_datetime_usec, null: false
      add :last_at, :utc_datetime_usec
      add :purged_at, :utc_datetime
      add :purged_by_id, references(:profiles, on_delete: :nilify_all)
    end

    create index(:group_changes, [:group_id, :id])
    create index(:group_changes, [:group_id, :subject_type, :id])
    create index(:group_changes, [:subject_type, :subject_id, :id])
    # What changed lately, for the sweep: rows come in the order of `at`.
    create index(:group_changes, [:at], using: :brin)
    create index(:group_changes, [:actor_id], where: "actor_id IS NOT NULL")
    create index(:group_changes, [:creator_id], where: "creator_id IS NOT NULL")
    create index(:group_changes, [:purged_by_id], where: "purged_by_id IS NOT NULL")

    create constraint(:group_changes, :group_changes_op_check,
             check: "op IN ('created', 'changed', 'deleted')"
           )

    create constraint(:group_changes, :group_changes_subject_type_check,
             check:
               "subject_type IN ('group', 'sub_group', 'shortcut', 'description', 'template', " <>
                 "'record', 'process', 'entity', 'field', 'message', 'reaction', " <>
                 "'group_reaction', 'poll', 'event', 'notice', 'app')"
           )

    # Emptied means there is nothing left to show.
    create constraint(:group_changes, :group_changes_purged_check,
             check: "purged_at IS NULL OR before IS NULL"
           )
  end
end
