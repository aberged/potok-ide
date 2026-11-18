defmodule PotokIde.Repo.Migrations.DropRedundantIndexes do
  use Ecto.Migration

  # Dropped concurrently, so writes go on meanwhile.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Indexes every write keeps up to date and no query needs (production's
  # scan counts on 2026-11-18 in brackets): each one is the leading column
  # of a wider index on the same table, which serves the same lookups and
  # the checks of foreign keys; Oban's two GIN indexes serve only unique jobs
  # and Oban Web, neither of which Potok uses, while a push job's args hold
  # up to 500 accounts; the chat's and data's order by time now go by id
  # (which grows with the time of writing), through the (group_id, id)
  # indexes. A chat value is then written into 4 indexes of `values`, not 6.
  @indexes [
    # (group_id, profile_id) unique [3,572, taken over by the wider one]
    {"group_memberships_group_id_index", "group_memberships (group_id)"},
    # (profile_id, group_id) unique [0]
    {"group_value_reads_profile_id_index", "group_value_reads (profile_id)"},
    # (account_id, profile_id) unique [0]
    {"accounts_profiles_account_id_index", "accounts_profiles (account_id)"},
    # (account_id, updated_at) [0]
    {"push_subscriptions_account_id_index", "push_subscriptions (account_id)"},
    # (group_id, requester_id) unique and (group_id, inserted_at, id) [0]
    {"group_join_requests_group_id_index", "group_join_requests (group_id)"},
    # (group_id, account_id) unique [0]
    {"group_account_invitations_group_id_index", "group_account_invitations (group_id)"},
    # [0]
    {"oban_jobs_args_index", "oban_jobs USING gin (args)"},
    {"oban_jobs_meta_index", "oban_jobs USING gin (meta)"},
    # (group_id, id) WHERE is_data = false [3, against 108,367 of the other]
    {"values_group_chat_order_index",
     ~s|"values" (group_id, inserted_at, id) WHERE (is_data = false)|},
    # (group_id, id) WHERE is_data = true [18]
    {"values_group_data_order_index",
     ~s|"values" (group_id, inserted_at, id) WHERE (is_data = true)|}
  ]

  def up do
    for {name, _definition} <- @indexes,
        do: execute("DROP INDEX CONCURRENTLY IF EXISTS #{name}")
  end

  def down do
    for {name, definition} <- @indexes,
        do: execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name} ON #{definition}")
  end
end
