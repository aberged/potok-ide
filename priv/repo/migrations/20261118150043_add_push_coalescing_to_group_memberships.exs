defmodule PotokIde.Repo.Migrations.AddPushCoalescingToGroupMemberships do
  use Ecto.Migration

  # The last value of the group a member got a push for, and when: the next
  # one waits until they have read up to it or five minutes have passed
  # (`Social.notify_group_members_of_new_value`). Not indexed, so the update
  # after every value stays a HOT update. A plain id, not a key: deleting the
  # value must not touch memberships.
  def change do
    alter table(:group_memberships) do
      add :last_push_value_id, :bigint
      add :last_pushed_at, :utc_datetime
    end
  end
end
