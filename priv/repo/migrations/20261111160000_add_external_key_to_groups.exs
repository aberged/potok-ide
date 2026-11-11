defmodule PotokIde.Repo.Migrations.AddExternalKeyToGroups do
  use Ecto.Migration

  # An app's own key for a sub-group it makes (`Social.create_children/4`):
  # unique under one parent, so a list brought in again makes no duplicates.
  # Groups with a key are records, such as rows of an open dataset brought in
  # by the thousand: their own map shows them, the root's map and the place
  # picker of events do not, so the indexes those read leave them out.
  def up do
    alter table(:groups) do
      add :external_key, :string
    end

    create constraint(:groups, :groups_external_key_check,
             check: "external_key IS NULL OR char_length(external_key) BETWEEN 1 AND 64"
           )

    create unique_index(:groups, [:parent_id, :external_key],
             where: "external_key IS NOT NULL",
             name: :groups_parent_external_key_index
           )

    # A map app reads the placed children of one group in a box.
    drop index(:groups, [:parent_id], name: :groups_placed_parent_index)

    create index(:groups, [:parent_id, :latitude, :longitude],
             where: "latitude IS NOT NULL",
             name: :groups_placed_parent_index
           )

    # The root's map and the place picker, without records.
    drop index(:groups, [:latitude, :longitude], name: :groups_place_index)

    create index(:groups, [:latitude, :longitude],
             where: "latitude IS NOT NULL AND external_key IS NULL",
             name: :groups_place_index
           )

    execute "DROP INDEX groups_pin_index"

    execute """
    CREATE INDEX groups_pin_index ON groups
    USING gist ((ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)))
    WHERE latitude IS NOT NULL AND external_key IS NULL
    """
  end

  def down do
    execute "DROP INDEX groups_pin_index"

    execute """
    CREATE INDEX groups_pin_index ON groups
    USING gist ((ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)))
    WHERE latitude IS NOT NULL
    """

    drop index(:groups, [:latitude, :longitude], name: :groups_place_index)

    create index(:groups, [:latitude, :longitude],
             where: "latitude IS NOT NULL",
             name: :groups_place_index
           )

    drop index(:groups, [:parent_id, :latitude, :longitude], name: :groups_placed_parent_index)

    create index(:groups, [:parent_id],
             where: "latitude IS NOT NULL",
             name: :groups_placed_parent_index
           )

    drop index(:groups, [:parent_id, :external_key], name: :groups_parent_external_key_index)
    drop constraint(:groups, :groups_external_key_check)

    alter table(:groups) do
      remove :external_key
    end
  end
end
