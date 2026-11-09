defmodule PotokIde.Repo.Migrations.AddLocationToGroups do
  use Ecto.Migration

  # Where a group stands on a map, and the pin it shows there
  # (`PotokIde.Social.GroupPins`). A pin is a key checked in code, so new pins
  # need no migration; an unknown one shows as the group's kind.
  #
  # The presets also take 'map' here, a deploy before anything writes it: a
  # machine still on the old code would fail to load a group with it.
  def up do
    alter table(:groups) do
      add :latitude, :float
      add :longitude, :float
      add :pin_icon, :string
    end

    # Both or neither, each within its range. Written out, as a comparison
    # with NULL would pass the check.
    create constraint(:groups, :groups_location_check,
             check: """
             (latitude IS NULL AND longitude IS NULL) OR \
             (latitude IS NOT NULL AND longitude IS NOT NULL \
             AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180)\
             """
           )

    # A map reads the placed children of one group.
    create index(:groups, [:parent_id],
             where: "latitude IS NOT NULL",
             name: :groups_placed_parent_index
           )

    drop constraint(:groups, :groups_preset_check)

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'announcements', 'feed', 'polls', 'questionnaire', 'page', 'map')"
           )
  end

  def down do
    drop constraint(:groups, :groups_preset_check)

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'announcements', 'feed', 'polls', 'questionnaire', 'page')"
           )

    drop index(:groups, [:parent_id], name: :groups_placed_parent_index)
    drop constraint(:groups, :groups_location_check)

    alter table(:groups) do
      remove :latitude
      remove :longitude
      remove :pin_icon
    end
  end
end
