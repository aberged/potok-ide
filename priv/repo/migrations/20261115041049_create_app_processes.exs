defmodule PotokIde.Repo.Migrations.CreateAppProcesses do
  use Ecto.Migration

  # The process of one collection of one app (`PotokIde.Social.AppProcesses`):
  # the profile that signs what it does, and the editor who owns it. Removing
  # the rule leaves the row inactive, so the process comes back with its own
  # profile; deleting the app or its group takes the row along, and the
  # profile goes once nothing it wrote is left.
  def change do
    create table(:app_processes) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false

      # nil: the app of the default description, as on `values`.
      add :alt_description_id,
          references(:group_alt_descriptions,
            with: [group_id: :group_id],
            on_delete: :delete_all
          )

      add :collection, :string, null: false
      # The rule's `process.name`, as last saved: what the chat and the
      # members show instead of the profile's generated username.
      add :name, :string, null: false
      add :owner_profile_id, references(:profiles, on_delete: :nilify_all)
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_processes, [:profile_id])

    # One process per collection of an app, also for the default description,
    # whose apps have no alt_description_id.
    create unique_index(:app_processes, [:group_id, :alt_description_id, :collection],
             nulls_distinct: false
           )

    create index(:app_processes, [:alt_description_id])
    create index(:app_processes, [:owner_profile_id])

    create constraint(:app_processes, :app_processes_collection_check,
             check: "collection ~ '^[a-z][a-z0-9_-]{0,39}$'"
           )
  end
end
