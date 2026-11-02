defmodule PotokIde.Repo.Migrations.CreateGroupEvents do
  use Ecto.Migration

  def change do
    create table(:group_events) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :creator_id, references(:profiles, on_delete: :nilify_all)
      # The chat value that announced the event.
      add :value_id, references(:values, on_delete: :nilify_all)
      add :title, :string, size: 200, null: false
      add :description, :text, null: false, default: ""
      add :location, :string, size: 300, null: false, default: ""
      add :all_day, :boolean, null: false, default: false
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      # IANA zone that keeps the wall-clock time of repeats.
      add :time_zone, :string, null: false
      add :recurrence, :string, null: false, default: "none"
      add :recurrence_interval, :integer, null: false, default: 1
      add :recurrence_weekdays, {:array, :integer}, null: false, default: []
      add :recurrence_monthly, :string, null: false, default: "day_of_month"
      add :recurrence_until, :date
      add :excluded_dates, {:array, :date}, null: false, default: []
      add :reminder_minutes, {:array, :integer}, null: false, default: []
      add :reminded_through, :utc_datetime, null: false
      add :next_reminder_at, :utc_datetime
      add :cancelled_at, :utc_datetime
      add :sequence, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:group_events, [:group_id, :starts_at])
    create index(:group_events, [:creator_id])
    create unique_index(:group_events, [:value_id], where: "value_id IS NOT NULL")
    # The reminder scheduler only looks at events with a reminder to come.
    create index(:group_events, [:next_reminder_at], where: "next_reminder_at IS NOT NULL")

    create constraint(:group_events, :group_events_ends_after_start,
             check: "ends_at >= starts_at"
           )

    create constraint(:group_events, :group_events_recurrence_check,
             check: "recurrence IN ('none', 'daily', 'weekly', 'monthly', 'yearly')"
           )

    create constraint(:group_events, :group_events_recurrence_monthly_check,
             check: "recurrence_monthly IN ('day_of_month', 'nth_weekday', 'last_weekday')"
           )

    create constraint(:group_events, :group_events_recurrence_interval_check,
             check: "recurrence_interval BETWEEN 1 AND 99"
           )

    # A member's answer for one occurrence, named by its local start date.
    create table(:group_event_responses) do
      add :event_id, references(:group_events, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :occurs_on, :date, null: false
      add :status, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_event_responses, [:event_id, :occurs_on, :profile_id])
    create index(:group_event_responses, [:profile_id])

    create constraint(:group_event_responses, :group_event_responses_status_check,
             check: "status IN ('going', 'maybe', 'declined')"
           )

    # A member's own reminders for an event, in place of the organizer's.
    create table(:group_event_member_settings) do
      add :event_id, references(:group_events, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :reminder_minutes, {:array, :integer}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:group_event_member_settings, [:event_id, :profile_id])
    create index(:group_event_member_settings, [:profile_id])
  end
end
