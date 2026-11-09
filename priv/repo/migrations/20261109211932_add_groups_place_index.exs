defmodule PotokIde.Repo.Migrations.AddGroupsPlaceIndex do
  use Ecto.Migration

  # The root's map asks for the groups in a box (`Social.list_map_cells/4`):
  # only groups with a place, by latitude first.
  def change do
    create index(:groups, [:latitude, :longitude],
             where: "latitude IS NOT NULL",
             name: :groups_place_index
           )
  end
end
