defmodule PotokIde.Repo.Migrations.AddLiveUntilToGroupEvents do
  use Ecto.Migration

  # The last day an event can still show in a calendar: its end for a single
  # one, the series' last date plus the 32 days an occurrence may last for a
  # repeating one (never before its first end), and no end for a series
  # without one. Kept by Postgres, so a calendar's window can skip the past
  # in SQL (`Events.list_occurrences/4`) instead of reading every event a
  # group ever had.
  def up do
    execute """
    ALTER TABLE group_events ADD COLUMN live_until date GENERATED ALWAYS AS (
      CASE
        WHEN recurrence = 'none' THEN ends_at::date
        WHEN recurrence_until IS NULL THEN 'infinity'::date
        ELSE GREATEST(ends_at::date, recurrence_until + 32)
      END
    ) STORED
    """

    create index(:group_events, [:group_id, :live_until],
             where: "cancelled_at IS NULL",
             name: :group_events_group_live_until_index
           )

    create index(:group_events, [:live_until],
             where: "is_public AND cancelled_at IS NULL",
             name: :group_events_public_live_until_index
           )
  end

  def down do
    drop index(:group_events, [:live_until], name: :group_events_public_live_until_index)

    drop index(:group_events, [:group_id, :live_until],
           name: :group_events_group_live_until_index
         )

    alter table(:group_events) do
      remove :live_until
    end
  end
end
