defmodule PotokIde.Repo.Migrations.CreateAppProfileEntries do
  use Ecto.Migration

  # An app's personal memory (`PotokIde.Social.AppProfileStore`): keys one app
  # keeps for one profile alone, such as how far a reader got in a site. It
  # goes with the app, its group and the profile; a deleted account deletes
  # its rows itself, as its profile stays (`PotokIde.Accounts.Deletion`).
  def change do
    create table(:app_profile_entries) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false

      # nil: the app of the default description, as on `values`.
      add :alt_description_id,
          references(:group_alt_descriptions,
            with: [group_id: :group_id],
            on_delete: :delete_all
          )

      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :key, :string, null: false
      # `{"v": value}`, a value being anything JSON holds.
      add :value, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_profile_entries, [:group_id, :alt_description_id, :profile_id, :key],
             nulls_distinct: false
           )

    create index(:app_profile_entries, [:profile_id])

    create index(:app_profile_entries, [:alt_description_id],
             where: "alt_description_id IS NOT NULL"
           )

    create constraint(:app_profile_entries, :app_profile_entries_key_check,
             check: "key ~ '^[A-Za-z0-9_.:-]{1,64}$'"
           )

    # 16 KB of JSON for the value, and the few bytes that wrap it.
    create constraint(:app_profile_entries, :app_profile_entries_value_check,
             check: "octet_length(value::text) <= 16500"
           )
  end
end
