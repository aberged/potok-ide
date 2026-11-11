defmodule PotokIde.Repo.Migrations.CreateGroupNotices do
  use Ecto.Migration

  def change do
    # A profile follows a group to receive its notices, member or not.
    create table(:group_follows) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      # Whether the follower's devices get a push for this group's notices.
      add :push, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    # Leads with group_id, so it also serves counting and reaching the followers.
    create unique_index(:group_follows, [:group_id, :profile_id])
    create index(:group_follows, [:profile_id])

    create table(:group_notices) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      # A deleted author leaves the notice with those who received it.
      add :creator_id, references(:profiles, on_delete: :nilify_all)
      add :body, :text, null: false
      add :recipients_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:group_notices, [:group_id, :id])
    create index(:group_notices, [:creator_id])

    create constraint(:group_notices, :group_notices_body_check,
             check: "char_length(body) BETWEEN 1 AND 2000 AND body ~ '[^[:space:]]'"
           )

    # One row per follower a notice reached: their inbox and its unread count.
    create table(:group_notice_receipts, primary_key: false) do
      add :profile_id, references(:profiles, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :notice_id, references(:group_notices, on_delete: :delete_all),
        null: false,
        primary_key: true

      # No time of its own: the notice's is when it arrived.
      add :read_at, :utc_datetime
    end

    # Deleting a notice reaches its receipts through this, not the primary key.
    create index(:group_notice_receipts, [:notice_id])

    # The counter: a profile's unread receipts, without reading the read ones.
    create index(:group_notice_receipts, [:profile_id],
             where: "read_at IS NULL",
             name: :group_notice_receipts_unread_index
           )

    # The profile's switch for the push of every notice it receives.
    alter table(:profiles) do
      add :notice_push, :boolean, null: false, default: true
    end
  end
end
