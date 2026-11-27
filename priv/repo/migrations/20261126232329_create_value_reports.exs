defmodule PotokIde.Repo.Migrations.CreateValueReports do
  use Ecto.Migration

  # A message someone reported to the admins of its group
  # (`PotokIde.Social.ValueReport`). It goes with the message: an admin who
  # deletes the message has dealt with it. A dismissed report stays, so the
  # same person does not report the same message again. A deleted account
  # removes its reports itself (`PotokIde.Accounts.Deletion`). History never
  # follows this table: who reported whom stays between them and the admins.
  def change do
    create table(:value_reports) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :value_id, references(:values, on_delete: :delete_all), null: false
      add :reporter_id, references(:profiles, on_delete: :delete_all), null: false

      add :reason, :string, null: false
      add :note, :text, null: false, default: ""

      # Set when an admin dismissed it; nil while it waits.
      add :dismissed_at, :utc_datetime
      add :dismissed_by_id, references(:profiles, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:value_reports, [:value_id, :reporter_id])
    create index(:value_reports, [:group_id, :id], where: "dismissed_at IS NULL")
    create index(:value_reports, [:reporter_id])
    create index(:value_reports, [:dismissed_by_id], where: "dismissed_by_id IS NOT NULL")

    create constraint(:value_reports, :value_reports_reason_check,
             check: "reason IN ('spam', 'abuse', 'inappropriate', 'other')"
           )

    create constraint(:value_reports, :value_reports_note_length,
             check: "char_length(note) <= 500"
           )
  end
end
