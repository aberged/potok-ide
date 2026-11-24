defmodule PotokIde.Repo.Migrations.AddDiscoveryToProfiles do
  use Ecto.Migration

  # Who may find a profile (`PotokIde.Social.Discovery`): everyone, also in
  # the suggestions when inviting; whoever knows its exact name or shares a
  # group with it (every profile so far: the suggestions stop reaching all of
  # Potok); or only whoever shares a group with it.
  def change do
    alter table(:profiles) do
      add :discovery, :string, null: false, default: "by_username"
    end

    create constraint(:profiles, :profiles_discovery_check,
             check: "discovery IN ('everyone', 'by_username', 'shared_groups')"
           )
  end
end
