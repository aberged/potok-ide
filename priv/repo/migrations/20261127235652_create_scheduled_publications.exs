defmodule PotokIde.Repo.Migrations.CreateScheduledPublications do
  use Ecto.Migration

  # A draft that opens to its readers at a time its editor picked
  # (`PotokIde.Social.ScheduledPublications`): one row per group, gone once it
  # is published, cancelled or published by hand. It goes with its group, and
  # a deleted account deletes its rows itself, as its profile stays
  # (`PotokIde.Accounts.Deletion`). History does not follow this table: the
  # publication itself is a change of the group, signed by who scheduled it.
  def change do
    create table(:scheduled_publications) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :publish_at, :utc_datetime, null: false

      # Whom it opens to then: public, and whether it takes all the parent's
      # members (it stops inheriting only by roles).
      add :is_public, :boolean, null: false
      add :inherits_members, :boolean, null: false

      # Why it was not published at its time; nil while it waits.
      add :failure, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:scheduled_publications, [:group_id])
    create index(:scheduled_publications, [:publish_at], where: "failure IS NULL")
    create index(:scheduled_publications, [:profile_id])

    create constraint(:scheduled_publications, :scheduled_publications_failure_check,
             check: "failure IN ('not_permitted', 'error')"
           )

    create constraint(:scheduled_publications, :scheduled_publications_audience_check,
             check: "is_public OR inherits_members"
           )
  end
end
