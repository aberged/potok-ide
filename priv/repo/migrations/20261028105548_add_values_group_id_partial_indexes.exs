defmodule PotokIde.Repo.Migrations.AddValuesGroupIdPartialIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Chat values: `max(id)` read markers, `id > last_read_value_id` unread
    # counts and keyset pagination (`id < before_id`) all filter by group and id.
    create index(:values, [:group_id, :id],
             where: "is_data = false",
             name: :values_group_chat_id_index,
             concurrently: true
           )

    # App data values: `after_id` / `before_id` cursors of the app API.
    create index(:values, [:group_id, :id],
             where: "is_data = true",
             name: :values_group_data_id_index,
             concurrently: true
           )
  end
end
