defmodule PotokIde.Repo.Migrations.AddOrdersPreset do
  use Ecto.Migration

  # A group can start as ordering together from a producer, with the Ordering
  # app. No group has the kind yet, so nothing is written.
  def up do
    drop constraint(:groups, :groups_preset_check)

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'feed', 'polls', 'questionnaire', 'page', 'map', 'orders')"
           )
  end

  # The groups made from it keep their app and lose only the kind.
  def down do
    execute "UPDATE groups SET preset = NULL WHERE preset = 'orders'"

    drop constraint(:groups, :groups_preset_check)

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'feed', 'polls', 'questionnaire', 'page', 'map')"
           )
  end
end
