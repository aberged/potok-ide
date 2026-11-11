defmodule PotokIde.Repo.Migrations.AddPlaceToGroupEvents do
  use Ecto.Migration

  # Where an event takes place on a map, next to the words of its `location`:
  # at a group's place (`place_group_id`, which follows the group) or at a
  # point of its own, never both. Deleting the group leaves the words.
  def change do
    alter table(:group_events) do
      add :place_group_id, references(:groups, on_delete: :nilify_all)
      add :latitude, :float
      add :longitude, :float
    end

    # Deleting a group clears the events placed at it.
    create index(:group_events, [:place_group_id], where: "place_group_id IS NOT NULL")

    # Both coordinates or neither, each within its range, and never with a
    # group. Written out, as a comparison with NULL would pass the check.
    create constraint(:group_events, :group_events_place_check,
             check: """
             (latitude IS NULL AND longitude IS NULL) OR \
             (latitude IS NOT NULL AND longitude IS NOT NULL \
             AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180 \
             AND place_group_id IS NULL)\
             """
           )
  end
end
