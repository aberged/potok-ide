defmodule PotokIde.Repo.Migrations.CreateScheduledValues do
  use Ecto.Migration

  # Messages a profile wrote to go out later (`PotokIde.Social.ScheduledValues`).
  # A row is gone once it is sent or cancelled. It goes with its group, and a
  # deleted account deletes its rows itself, as its profile stays
  # (`PotokIde.Accounts.Deletion`). History never follows this table: it keeps
  # no text of messages.
  def change do
    create table(:scheduled_values) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false

      # The message it answers; it goes out without a quote when that is gone.
      add :parent_id, references(:values, on_delete: :nilify_all)

      add :content, :text, null: false, default: ""

      # Files already in storage, which become attachments of the message.
      add :files, {:array, :map}, null: false, default: []

      add :send_at, :utc_datetime, null: false

      # Why it was not sent at its time; nil while it waits.
      add :failure, :string

      timestamps(type: :utc_datetime)
    end

    create index(:scheduled_values, [:send_at], where: "failure IS NULL")
    create index(:scheduled_values, [:group_id, :profile_id])
    create index(:scheduled_values, [:profile_id])
    create index(:scheduled_values, [:parent_id], where: "parent_id IS NOT NULL")

    create constraint(:scheduled_values, :scheduled_values_failure_check,
             check: "failure IN ('late', 'not_permitted', 'error')"
           )
  end
end
