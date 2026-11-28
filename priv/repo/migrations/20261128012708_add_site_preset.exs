defmodule PotokIde.Repo.Migrations.AddSitePreset do
  use Ecto.Migration

  # A group can start as a site, with the Sajt app (menus, sections,
  # articles, themes). No group has the kind yet, so nothing is written.
  def up do
    drop constraint(:groups, :groups_preset_check)

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'feed', 'polls', 'questionnaire', 'page', 'map', 'orders', 'site')"
           )
  end

  # The groups made from it keep their app and lose only the kind.
  def down do
    execute "UPDATE groups SET preset = NULL WHERE preset = 'site'"

    drop constraint(:groups, :groups_preset_check)

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'feed', 'polls', 'questionnaire', 'page', 'map', 'orders')"
           )
  end
end
