defmodule PotokIde.Repo.Migrations.AddValuesAltDescriptionIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # App API cursors of alternative descriptions' apps, and the cascade when
    # one is deleted. Only data values get an alt_description_id; the cascade's
    # lookup has no `is_data` filter, so the predicate must not have one either.
    create index(:values, [:alt_description_id, :id],
             where: "alt_description_id IS NOT NULL",
             name: :values_alt_description_data_id_index,
             concurrently: true
           )

    # Lets deleting an alternative description clear the home pointer
    # without scanning every group.
    create index(:groups, [:home_alt_description_id],
             where: "home_alt_description_id IS NOT NULL",
             concurrently: true
           )
  end
end
