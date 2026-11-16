defmodule PotokIde.Repo.Migrations.AddDrawnProcesses do
  use Ecto.Migration

  # Processes an editor draws in Potok (`PotokIde.Social.DrawnProcesses`): they
  # hang on a collection of an app like the app's own process, but their graph
  # lives here, where no save of the app's config can reach it. A collection
  # keeps at most one process of its app, and may have drawn ones beside it.
  def up do
    alter table(:app_processes) do
      add :drawn, :boolean, null: false, default: false
      # The normalized graph of a drawn process; the app's own lives in its rules.
      add :graph, :map
      # Where its elements stand on a wide screen: %{"nodes" => %{id => [x, y]}}.
      add :layout, :map, null: false, default: %{}
      # The revision two editors of one drawing check against each other.
      add :lock_version, :integer, null: false, default: 1
    end

    drop index(:app_processes, [:group_id, :alt_description_id, :collection])

    create unique_index(:app_processes, [:group_id, :alt_description_id, :collection],
             nulls_distinct: false,
             where: "NOT drawn",
             name: :app_processes_app_collection_index
           )

    create index(:app_processes, [:group_id, :alt_description_id, :collection],
             where: "drawn AND active",
             name: :app_processes_drawn_active_index
           )

    create constraint(:app_processes, :app_processes_drawn_graph_check,
             check: "drawn = (graph IS NOT NULL)"
           )
  end

  def down do
    execute "DELETE FROM app_processes WHERE drawn"

    drop constraint(:app_processes, :app_processes_drawn_graph_check)

    drop index(:app_processes, [:group_id, :alt_description_id, :collection],
           name: :app_processes_drawn_active_index
         )

    drop index(:app_processes, [:group_id, :alt_description_id, :collection],
           name: :app_processes_app_collection_index
         )

    create unique_index(:app_processes, [:group_id, :alt_description_id, :collection],
             nulls_distinct: false
           )

    alter table(:app_processes) do
      remove :lock_version
      remove :layout
      remove :graph
      remove :drawn
    end
  end
end
